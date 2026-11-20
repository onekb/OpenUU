use thiserror::Error;

#[derive(Debug, Error)]
pub enum ChameyeError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("protobuf decode error: {0}")]
    ProtoDecode(#[from] prost::DecodeError),

    #[error("protobuf encode error: {0}")]
    ProtoEncode(#[from] prost::EncodeError),

    #[error("QUIC connection error: {0}")]
    Connection(#[from] quinn::ConnectionError),

    #[error("QUIC connect error: {0}")]
    Connect(#[from] quinn::ConnectError),

    #[error("QUIC write error: {0}")]
    Write(#[from] quinn::WriteError),

    #[error("QUIC read error: {0}")]
    Read(#[from] quinn::ReadExactError),

    #[error("TLS / crypto error: {0}")]
    Crypto(String),

    #[error("mDNS discovery error: {0}")]
    Discovery(String),

    #[error("protocol error: {0}")]
    Protocol(String),

    #[error("pairing rejected: {0}")]
    PairingRejected(String),
}

pub type Result<T> = std::result::Result<T, ChameyeError>;
