//! A program for encrypting/decrypting a file in AES CTR mode.
//! The key and IV are generated automatically and saved to separate files.
//!
//! ## Authors
//!
//! The Veracruz Development Team.
//!
//! ## Licensing and copyright notice
//!
//! See the `LICENSE_MIT.markdown` file in the Veracruz root directory for
//! information on licensing and copyright.

use mbedtls::{
    cipher::{Cipher, Decryption, Encryption, Fresh, Traditional},
    rng::{CtrDrbg, OsEntropy, Random},
};
use std::{fs, path::PathBuf, sync::Arc};
use structopt::StructOpt;

// Cipher's key length in bits
static KEY_LENGTH: u32 = 128;

// Cipher's block size in bits
static BLOCK_SIZE: u32 = 128;

#[derive(Debug, StructOpt)]
#[structopt(name = "options")]
struct Opt {
    /// Path to input file
    #[structopt(parse(from_os_str))]
    input_file: PathBuf,

    /// Path to output file
    #[structopt(parse(from_os_str))]
    output_file: PathBuf,

    /// Path to key file
    #[structopt(parse(from_os_str))]
    key_file: PathBuf,

    /// Path to IV file
    #[structopt(parse(from_os_str))]
    iv_file: PathBuf,

    /// Whether the input file should be encrypted or encrypted
    #[structopt(short = "e", long = "encrypt")]
    is_encryption: bool,
}

fn get_rng(size: usize) -> Result<Vec<u8>, mbedtls::Error> {
    let entropy = Arc::new(OsEntropy::new());
    let mut rng = CtrDrbg::new(entropy, None)?;
    let mut random_bytes = vec![0u8; size];
    rng.random(&mut random_bytes)?;
    Ok(random_bytes)
}

fn main() -> anyhow::Result<()> {
    let opt = Opt::from_args();

    // Read the input file
    let input = fs::read(&opt.input_file)?;

    let mut output = Vec::new();

    if opt.is_encryption {
        // Try to load key and IV. Generate them if they don't exist
        let key = match fs::read(&opt.key_file) {
            Ok(r) => r,
            Err(_) => {
                println!("Key doesn't exist. Generating it");
                get_rng((KEY_LENGTH / 8) as usize)?
            }
        };
        let iv = match fs::read(&opt.iv_file) {
            Ok(r) => r,
            Err(_) => {
                println!("IV doesn't exist. Generating it");
                get_rng((BLOCK_SIZE / 8) as usize)?
            }
        };

        // Check lengths
        assert!(
            key.len() == KEY_LENGTH as usize / 8,
            "Invalid key length. Should be {} bits long",
            KEY_LENGTH
        );
        assert!(
            iv.len() == BLOCK_SIZE as usize / 8,
            "Invalid IV length. Should be {} bits long",
            BLOCK_SIZE
        );

        let cipher: Cipher<Encryption, Traditional, Fresh> = mbedtls::cipher::Cipher::new(
            mbedtls::cipher::raw::CipherId::Aes,
            mbedtls::cipher::raw::CipherMode::CTR,
            KEY_LENGTH,
        )?;

        let block_size = cipher.block_size();
        let padded_size = (input.len() + 2 * block_size - 1) / block_size * block_size;

        output.resize(padded_size, 0);

        cipher
            .set_key_iv(&key[..], &iv[..])?
            .encrypt(&input, &mut output)?;

        // Save key and IV
        fs::write(&opt.key_file, &key)?;
        fs::write(&opt.iv_file, &iv)?;
    } else {
        // Try to load key and IV
        let key = fs::read(&opt.key_file)?;
        let iv = fs::read(&opt.iv_file)?;

        // Check lengths
        assert!(
            key.len() == KEY_LENGTH as usize / 8,
            "Invalid key length. Should be {} bits long",
            KEY_LENGTH
        );
        assert!(
            iv.len() == BLOCK_SIZE as usize / 8,
            "Invalid IV length. Should be {} bits long",
            BLOCK_SIZE
        );

        let cipher: Cipher<Decryption, Traditional, Fresh> = mbedtls::cipher::Cipher::new(
            mbedtls::cipher::raw::CipherId::Aes,
            mbedtls::cipher::raw::CipherMode::CTR,
            KEY_LENGTH,
        )?;

        let block_size = cipher.block_size();
        let padded_size = (input.len() + 2 * block_size - 1) / block_size * block_size;
        output.resize(padded_size, 0);

        cipher
            .set_key_iv(&key[..], &iv[..])?
            .decrypt(&input, &mut output)?;
    }

    // We only need as many bytes from the output as the input
    output.resize(input.len(), 0);

    // Save output
    fs::write(&opt.output_file, &output)?;

    Ok(())
}
