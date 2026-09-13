use std::env::VarError;
use std::io;
use std::time::Duration;

use app_test_support::ChatGptIdTokenClaims;
use app_test_support::encode_id_token;
use codex_config::types::AuthCredentialsStoreMode;
use codex_http_client::HttpClientBuilder;
use codex_login::AuthKeyringBackendKind;
use codex_login::ExpectedLoginEmail;
use codex_login::ServerOptions;
use codex_login::login_with_api_key;
use pretty_assertions::assert_eq;
use serde_json::json;
use tempfile::TempDir;
use wiremock::Mock;
use wiremock::MockServer;
use wiremock::ResponseTemplate;
use wiremock::matchers::method;
use wiremock::matchers::path;

use super::parse_expected_login_email;
use super::start_chatgpt_login;

#[test]
fn expected_login_email_is_optional_only_when_environment_variable_is_absent() -> io::Result<()> {
    assert_eq!(parse_expected_login_email(Err(VarError::NotPresent))?, None);
    for value in ["", " \t\n", "invalid-address"] {
        let error = parse_expected_login_email(Ok(value.to_string()))
            .expect_err("invalid configured email must fail");
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
    Ok(())
}

#[test]
fn expected_login_email_from_environment_is_normalized() -> io::Result<()> {
    assert_eq!(
        parse_expected_login_email(Ok(" USER@EXAMPLE.COM \n".to_string()))?,
        Some(ExpectedLoginEmail::parse("user@example.com")?)
    );
    Ok(())
}

#[test]
fn expected_login_email_rejects_non_unicode_environment_values() {
    let error = parse_expected_login_email(Err(VarError::NotUnicode("invalid".into())))
        .expect_err("non-Unicode configured email must fail");
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[tokio::test]
async fn expected_login_email_preserves_existing_credentials_through_cli_reauthentication()
-> anyhow::Result<()> {
    let issuer = MockServer::start().await;
    let wrong_identity =
        encode_id_token(&ChatGptIdTokenClaims::new().email("another@example.com"))?;
    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id_token": wrong_identity,
            "access_token": "mock-access-token",
            "refresh_token": "mock-refresh-token",
        })))
        .expect(1)
        .mount(&issuer)
        .await;
    let codex_home = TempDir::new()?;
    login_with_api_key(
        codex_home.path(),
        "mock-existing-api-key",
        AuthCredentialsStoreMode::File,
        AuthKeyringBackendKind::Direct,
    )?;
    let auth_path = codex_home.path().join("auth.json");
    let existing_auth = std::fs::read(&auth_path)?;
    let mut opts = ServerOptions::new(
        codex_home.path().to_path_buf(),
        codex_login::CLIENT_ID.to_string(),
        /*forced_chatgpt_workspace_id*/ None,
        AuthCredentialsStoreMode::File,
        AuthKeyringBackendKind::Direct,
        codex_login::test_support::transport_default_auth_route_config(),
    );
    opts.expected_email = parse_expected_login_email(Ok("registered@example.com".to_string()))?;
    opts.issuer = issuer.uri();
    opts.port = 0;
    opts.open_browser = false;
    opts.force_state = Some("reauthentication-state".to_string());

    let server = start_chatgpt_login(opts).await?;
    assert_eq!(std::fs::read(&auth_path)?, existing_auth);
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
        .expect_err("the CLI login must reject a different account");
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(std::fs::read(auth_path)?, existing_auth);
    Ok(())
}
