// Adapted from Arti tor-llcrypto 0.35.0 tests/testvec.rs (MIT OR Apache-2.0).
// Public Chutney fixture: verifies canonical DER, the established Tor identity,
// historical signatures, and signing after the RSA API migration.
use base64ct::{Base64Unpadded, Encoding as _};
use hex_literal::hex;

#[test]
fn preserves_published_tor_rsa_identity_and_signature_vectors() {
    // These vectors are taken from a chutney installation, not a standard
    // source.

    let sk_pem = "
MIICXQIBAAKBgQDVJ7bGPW6B05wyipTOFX3M3AROsa2MIQycniJIe0z63m1AQb0Q
Rpplfj2CvADPYqw7apkkflc7VMEMR/XchJsKzNoDHspvbl3IVnf3bexJ/yTS/LK1
iH+xJaogR0QRm7ZBf0XuaW+N/Bwvwhsrro6eN6GdwlGKLCTn2P1/rA9GlQIDAQAB
AoGADZDgfg9s2BBqsYDGZbNSdVZPY97FB9UWo2UhE3HdfV3ooB1O9hk4PFtjeM2U
U56ZDZMEOiFcVedX/fsad7Vs1I5VUxwZqXdhRgqJllD5RPifSSpt3lnYNE0O/WN5
DJIUR2yxJ2cXj2D2MUh56T5RnqC17lXWEOmUUlM7u2/po8ECQQD6HVmhcclRWWP8
/IuSu8rD/2kjjuoAhg1ptfSyzSIp0ipS7xYcru13dDkFG8WllosEt0eu+FIL+Vnz
VtxyBErRAkEA2iu5yiRSVRHOud2SHtn1wUx2M8pSdB3XtCQjkpiwhsSij20eYFVv
clS5A6E0D4txRK4flnwYqVTdxlh271fohQJBAMKZ+XX6oWeRBJH/MN1/DZmH7RcE
iB7WLjN0pipEHvOpGNMkQPEaTZsmq4LFA/f9dLa7n6OMg9HbNdh2WdjAbDECQFqT
9tG23LvW5dYC6KyIX2C+ZwC/ihYNYcW3j1FItVluf/M+IXNrZRa5mAqqvduKUB9s
j07B/Ncold7IUbCy9aUCQQDew08R5vjl8n+I44u/KIZ4RR1ntggrnDfKnCD8nNR4
LnZEGsos1BCJkS31lYl7Jae1QVooa6522Rz8ORo+GfbZ";
    let pk_pem = "
MIGJAoGBANUntsY9boHTnDKKlM4VfczcBE6xrYwhDJyeIkh7TPrebUBBvRBGmmV+
PYK8AM9irDtqmSR+VztUwQxH9dyEmwrM2gMeym9uXchWd/dt7En/JNL8srWIf7El
qiBHRBGbtkF/Re5pb438HC/CGyuujp43oZ3CUYosJOfY/X+sD0aVAgMBAAE";
    fn to_der(s: &str) -> Vec<u8> {
        let mut r = Vec::new();
        for line in s.lines() {
            r.extend(Base64Unpadded::decode_vec(line).unwrap());
        }
        r
    }

    use tor_llcrypto::pk::{ValidatableSignature, rsa};

    let secret = rsa::KeyPair::from_der(&to_der(sk_pem)).unwrap();
    let expect_public = rsa::PublicKey::from_der(&to_der(pk_pem)).unwrap();

    let public = secret.to_public_key();
    assert_eq!(public.to_rsa_identity(), expect_public.to_rsa_identity());
    assert_eq!(
        format!("{}", public.to_rsa_identity()),
        "$9367f9781da8eabbf96b691175f0e701b43c602e"
    );
    assert_eq!(
        format!("{:?}", public.to_rsa_identity()),
        "RsaIdentity { $9367f9781da8eabbf96b691175f0e701b43c602e }"
    );

    assert_eq!(
        rsa::RsaIdentity::from_bytes(&hex!("9367f9781da8eabbf96b691175f0e701b43c602e")).unwrap(),
        public.to_rsa_identity()
    );
    assert_eq!(
        &hex!("9367f9781da8eabbf96b691175f0e701b43c602e"),
        public.to_rsa_identity().as_bytes()
    );

    assert!(
        rsa::RsaIdentity::from_bytes(&hex!("67f9781da8eabbf96b691175f0e701b43c602e")).is_none()
    );
    assert!(
        rsa::RsaIdentity::from_bytes(&hex!("67f9781da8eabbf96b691175f0e701b43c602effff")).is_none()
    );

    assert_eq!(public.to_der(), to_der(pk_pem));
    assert_eq!(public.bits(), 1024);
    assert!(public.exponent_is(65537));
    assert!(!public.exponent_is(3));

    let digest = hex!("8c28f494a3ca4522926b177124a51158a790bec0");
    let wrong_digest = hex!("8c28f494a3ca4522926b177124a51158a790bec1");
    let sig = "
i7BWpY6EgPCYQQQRL8yIba+2C/sASVWMmcD5x/aSlGVeuwna4h15SrOKAMZUBecE
JtAqSDuSzXGn6FP9WXNdi+xe5GQznb1D3wjParTno1y/kYtJiRA5MrJ0E1cWhLl5
rI2rzhqqBIhzFFaYuxyRAhkSBxCKTdl6X0k74ahT3MM
";

    assert!(public.verify(&digest, &to_der(sig)).is_ok());
    assert!(public.verify(&wrong_digest, &to_der(sig)).is_err());

    let val = rsa::ValidatableRsaSignature::new(&public, &to_der(sig), &digest);

    assert!(val.is_valid());
}
