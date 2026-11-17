fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .build_client(true)
        .build_server(false)  // panel is gRPC client only, not server
        .compile_protos(
            &["../proto/azimut.proto"],
            &["../proto"],
        )?;
    Ok(())
}
