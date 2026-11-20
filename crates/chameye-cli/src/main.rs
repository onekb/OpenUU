use std::net::SocketAddr;
use std::time::Duration;

use chameye_core::discovery::DiscoveryService;
use chameye_core::identity::{generate_pairing_pin, DeviceIdentity};
use chameye_core::protocol::pb;
use chameye_core::transport::{accept_client_session, bind_host_endpoint, connect_to_host};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter("info,chameye_core=debug")
        .init();

    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("host") => {
            let port: u16 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(39481);
            let identity = DeviceIdentity::load_or_create(None, None)?;
            let pin = generate_pairing_pin();
            let addr: SocketAddr = format!("0.0.0.0:{port}").parse()?;
            let endpoint = bind_host_endpoint(&identity, addr)?;
            let bound_port = endpoint.local_addr()?.port();

            let discovery = DiscoveryService::new()?;
            discovery.advertise(&identity.device_id, &identity.device_name, std::env::consts::OS, bound_port)?;

            println!("Chameye Host listening on UDP port {bound_port}");
            println!("Pairing PIN: {pin}");
            println!("Waiting for Client...");

            let (session, mut channels, hello) =
                accept_client_session(&endpoint, &identity, Some(&pin)).await?;
            println!("Client connected: {} ({})", hello.device_name, hello.os);

            while let Some(env) = channels.control_rx.recv().await {
                println!("Received control: {:?}", env.payload);
                if let Some(pb::control_envelope::Payload::Ping(p)) = env.payload {
                    let pong = pb::ControlEnvelope {
                        seq: env.seq + 1,
                        payload: Some(pb::control_envelope::Payload::Pong(pb::Pong {
                            timestamp_us: p.timestamp_us,
                        })),
                    };
                    session.send_control(&pong).await?;
                }
            }
        }
        Some("discover") => {
            let discovery = DiscoveryService::new()?;
            discovery.start_browsing(None)?;
            println!("Browsing LAN for Chameye Hosts (5s)...");
            tokio::time::sleep(Duration::from_secs(5)).await;
            let peers = discovery.list_peers();
            if peers.is_empty() {
                println!("No Chameye Hosts found.");
            } else {
                for p in peers {
                    println!("- {} ({}) {:?}:{}", p.device_name, p.os, p.addresses, p.port);
                }
            }
        }
        Some("client") => {
            let addr_str = args
                .get(2)
                .ok_or("usage: chameye-cli client <ip:port> <pin>")?;
            let pin = args
                .get(3)
                .ok_or("usage: chameye-cli client <ip:port> <pin>")?;
            let addr: SocketAddr = addr_str.parse()?;
            let identity = DeviceIdentity::load_or_create(None, None)?;
            let (session, mut channels, ack) = connect_to_host(&identity, addr, pin).await?;
            println!("Connected to Host: {} ({})", ack.device_name, ack.os);

            let ping = pb::ControlEnvelope {
                seq: 2,
                payload: Some(pb::control_envelope::Payload::Ping(pb::Ping {
                    timestamp_us: 42,
                })),
            };
            session.send_control(&ping).await?;
            if let Some(resp) = channels.control_rx.recv().await {
                println!("Host replied: {:?}", resp.payload);
            }
            session.close();
        }
        _ => {
            println!("Usage:");
            println!("  chameye-cli host [port]");
            println!("  chameye-cli discover");
            println!("  chameye-cli client <ip:port> <pin>");
        }
    }

    Ok(())
}
