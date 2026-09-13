use std::io;
use std::path::Path;
use std::time::Duration;

use anyhow::Result;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use codex_config::types::AuthCredentialsStoreMode;
use codex_http_client::HttpClientBuilder;
use codex_login::AuthKeyringBackendKind;
use codex_login::ExpectedLoginEmail;
use codex_login::ServerOptions;
use codex_login::run_login_server;
use core_test_support::skip_if_no_network;
use pretty_assertions::assert_eq;
use serde_json::Value;
use serde_json::json;
use tempfile::tempdir;
use wiremock::Mock;
use wiremock::MockServer;
use wiremock::ResponseTemplate;
use wiremock::matchers::body_string_contains;
use wiremock::matchers::method;
use wiremock::matchers::path;

fn id_token(claims: Value) -> Result<String> {
    let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"none","typ":"JWT"}"#);
    let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims)?);
    let signature = URL_SAFE_NO_PAD.encode(b"mock-signature");
    Ok(format!("{header}.{payload}.{signature}"))
}

async fn mock_issuer(id_token: &str) -> MockServer {
    let issuer = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .and(body_string_contains("grant_type=authorization_code"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id_token": id_token,
            "access_token": "mock-access-token",
            "refresh_token": "mock-refresh-token",
        })))
        .expect(1)
        .mount(&issuer)
        .await;
    issuer
}

fn login_options(codex_home: &Path, issuer: &MockServer) -> Result<ServerOptions> {
    let mut options = ServerOptions::new(
        codex_home.to_path_buf(),
        codex_login::CLIENT_ID.to_string(),
        /*forced_chatgpt_workspace_id*/ None,
        AuthCredentialsStoreMode::File,
        AuthKeyringBackendKind::Direct,
        codex_login::test_support::transport_default_auth_route_config(),
    );
    options.issuer = issuer.uri();
    options.port = 0;
    options.open_browser = false;
    options.force_state = Some("reauthentication-state".to_string());
    options.expected_email = Some(ExpectedLoginEmail::parse(" REGISTERED@EXAMPLE.COM \t")?);
    Ok(options)
}

#[tokio::test]
async fn reauthentication_persists_only_the_expected_account() -> Result<()> {
    skip_if_no_network!(Ok(()));

    let expected_token = id_token(json!({
        "email": " Registered@Example.Com ",
        "https://api.openai.com/auth": {"chatgpt_account_id": "registered-account"},
    }))?;
    let issuer = mock_issuer(&expected_token).await;
    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .and(body_string_contains("grant_type=urn%3Aietf"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "access_token": "mock-api-key",
        })))
        .expect(1)
        .mount(&issuer)
        .await;
    let codex_home = tempdir()?;
    let server = run_login_server(login_options(codex_home.path(), &issuer)?)?;
    let port = server.actual_port;
    let response = HttpClientBuilder::new()
        .build_direct()?
        .get(format!(
            "http://127.0.0.1:{port}/auth/callback?code=mock-code&state=reauthentication-state"
        ))
        .send()
        .await?;
    assert!(response.status().is_success());
    tokio::time::timeout(Duration::from_secs(5), server.block_until_done()).await??;

    let saved: Value =
        serde_json::from_slice(&std::fs::read(codex_home.path().join("auth.json"))?)?;
    assert_eq!(
        saved["tokens"],
        json!({
            "id_token": expected_token,
            "access_token": "mock-access-token",
            "refresh_token": "mock-refresh-token",
            "account_id": "registered-account",
        })
    );
    Ok(())
}

#[tokio::test]
async fn reauthentication_rejects_unverified_identity_without_changing_stored_credentials()
-> Result<()> {
    skip_if_no_network!(Ok(()));

    let existing_auth = serde_json::to_vec_pretty(&json!({
        "auth_mode": "chatgpt",
        "tokens": {
            "id_token": id_token(json!({"email": "registered@example.com"}))?,
            "access_token": "existing-access-token",
            "refresh_token": "existing-refresh-token",
            "account_id": "registered-account",
        },
    }))?;
    let unverified_tokens = [
        id_token(json!({"email": "another@example.com"}))?,
        id_token(json!({}))?,
        id_token(json!({"email": "invalid-address"}))?,
        "invalid-identity-token".to_string(),
    ];
    for rejected_token in unverified_tokens {
        for original_auth in [None, Some(&existing_auth)] {
            let issuer = mock_issuer(&rejected_token).await;
            let codex_home = tempdir()?;
            let auth_path = codex_home.path().join("auth.json");
            if let Some(original_auth) = original_auth {
                std::fs::write(&auth_path, original_auth)?;
            }
            let server = run_login_server(login_options(codex_home.path(), &issuer)?)?;
            let port = server.actual_port;
            let response = HttpClientBuilder::new()
                .without_redirects()
                .build_direct()?
                .get(format!(
                    "http://127.0.0.1:{port}/auth/callback?code=mock-code&state=reauthentication-state"
                ))
                .send()
                .await?;
            assert_eq!(response.status(), 200);
            let error = tokio::time::timeout(Duration::from_secs(5), server.block_until_done())
                .await?
                .expect_err("an unverified identity must be rejected");
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
            match original_auth {
                Some(original_auth) => assert_eq!(std::fs::read(&auth_path)?, *original_auth),
                None => assert!(!auth_path.exists()),
            }
            assert_eq!(
                issuer
                    .received_requests()
                    .await
                    .expect("mock requests must be available")
                    .len(),
                1,
                "an unverified identity must not reach the API key exchange"
            );
        }
    }
    Ok(())
}
