fn main() -> Result<(), Box<dyn std::error::Error>> {
    let protoc = protoc_bin_vendored::protoc_bin_path()?;
    std::env::set_var("PROTOC", protoc);

    println!("cargo:rerun-if-changed=../../proto/chameye.proto");
    prost_build::Config::new()
        .compile_protos(&["../../proto/chameye.proto"], &["../../proto"])?;
    Ok(())
}
