use std::{env, fs, path::Path};

/// The web app is embedded from `../app/build/web`. Make sure the folder
/// exists so the server still compiles (serving no web app) before the first
/// `flutter build web`.
fn main() {
    if env::var_os("CARGO_FEATURE_EMBED_WEB").is_some() {
        let web = Path::new(&env::var("CARGO_MANIFEST_DIR").unwrap()).join("../app/build/web");
        fs::create_dir_all(&web).expect("create ../app/build/web");
        println!("cargo:rerun-if-changed={}", web.display());
    }
}
