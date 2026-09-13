use std::io;

use pretty_assertions::assert_eq;

use super::ExpectedLoginEmail;

#[test]
fn rejects_empty_or_invalid_expected_login_emails() {
    for email in [
        "",
        " \t\n",
        "missing-at",
        "@example.com",
        "user@",
        "user@@example.com",
        "user name@example.com",
        "user\0@example.com",
    ] {
        let error = ExpectedLoginEmail::parse(email).expect_err("email must be rejected");
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
}
