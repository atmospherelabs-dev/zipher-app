//! Preserve the wallet SDK's RNG API while calling Zakura's rand_core 0.10 APIs.
//! No new entropy source: every operation delegates to the original generator.

use core::convert::Infallible;

pub struct From06<R>(pub R);

pub const OS_RNG: From06<rand_core_06::OsRng> = From06(rand_core_06::OsRng);

impl<R: rand_core_06::RngCore> rand_core::TryRng for From06<R> {
    type Error = Infallible;

    fn try_next_u32(&mut self) -> Result<u32, Self::Error> {
        Ok(self.0.next_u32())
    }

    fn try_next_u64(&mut self) -> Result<u64, Self::Error> {
        Ok(self.0.next_u64())
    }

    fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), Self::Error> {
        self.0.fill_bytes(dest);
        Ok(())
    }
}

impl<R: rand_core_06::CryptoRng + rand_core_06::RngCore> rand_core::TryCryptoRng for From06<R> {}

#[cfg(test)]
mod tests {
    use super::*;
    use rand_core::Rng;
    use rand_core_06::{RngCore, SeedableRng};

    #[test]
    fn preserves_the_underlying_random_stream() {
        let mut original = rand_chacha::ChaCha20Rng::from_seed([42; 32]);
        let mut adapted = From06(original.clone());
        assert_eq!(original.next_u32(), adapted.next_u32());
        assert_eq!(original.next_u64(), adapted.next_u64());
        let (mut expected, mut actual) = ([0; 97], [0; 97]);
        original.fill_bytes(&mut expected);
        adapted.fill_bytes(&mut actual);
        assert_eq!(expected, actual);
    }
}
