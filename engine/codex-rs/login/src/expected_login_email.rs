use std::io;

use crate::token_data::parse_chatgpt_jwt_claims;

/// The registered identity that must be verified before replacing login credentials.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpectedLoginEmail(String);

impl ExpectedLoginEmail {
    pub fn parse(email: &str) -> io::Result<Self> {
        normalized_email(email).map(Self).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Expected login email is invalid.",
            )
        })
    }

    pub(crate) fn verify_id_token(&self, id_token: &str) -> Result<(), &'static str> {
        let identity = parse_chatgpt_jwt_claims(id_token)
            .map_err(|_| "Sign-in did not return a valid identity token.")?;
        let email = identity
            .email
            .as_deref()
            .and_then(normalized_email)
            .ok_or("Sign-in did not return a valid account email address.")?;
        if email != self.0 {
            return Err(
                "The signed-in account does not match the registered account. Sign in with the registered account.",
            );
        }
        Ok(())
    }
}

fn normalized_email(email: &str) -> Option<String> {
    let email = email.trim().to_lowercase();
    let (local, domain) = email.split_once('@')?;
    if local.is_empty()
        || domain.is_empty()
        || domain.contains('@')
        || email.chars().any(char::is_whitespace)
        || email.chars().any(char::is_control)
    {
        return None;
    }
    Some(email)
}

#[cfg(test)]
#[path = "expected_login_email_tests.rs"]
mod tests;
