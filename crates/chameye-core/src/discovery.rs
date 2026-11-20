use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};

use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use serde::{Deserialize, Serialize};
use tracing::{debug, warn};

use crate::error::{ChameyeError, Result};
use crate::protocol::PROTOCOL_VERSION;

pub const SERVICE_TYPE: &str = "_chameye._udp.local.";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredPeer {
    pub device_id: String,
    pub device_name: String,
    pub os: String,
    pub addresses: Vec<IpAddr>,
    pub port: u16,
    pub protocol_version: u32,
}

pub struct DiscoveryService {
    daemon: ServiceDaemon,
    peers: Arc<Mutex<HashMap<String, DiscoveredPeer>>>,
    registered_fullname: Mutex<Option<String>>,
}

impl DiscoveryService {
    pub fn new() -> Result<Self> {
        let daemon = ServiceDaemon::new()
            .map_err(|e| ChameyeError::Discovery(format!("mdns daemon init failed: {e}")))?;
        Ok(Self {
            daemon,
            peers: Arc::new(Mutex::new(HashMap::new())),
            registered_fullname: Mutex::new(None),
        })
    }

    /// Advertise this device as a Chameye Host on the LAN.
    pub fn advertise(
        &self,
        device_id: &str,
        device_name: &str,
        os: &str,
        port: u16,
    ) -> Result<()> {
        let instance_name = format!("chameye-{}", &device_id[..device_id.len().min(8)]);
        let host_label = format!("{instance_name}.local.");
        let mut props = HashMap::new();
        props.insert("v".to_string(), PROTOCOL_VERSION.to_string());
        props.insert("id".to_string(), device_id.to_string());
        props.insert("name".to_string(), device_name.to_string());
        props.insert("os".to_string(), os.to_string());

        let service_info = ServiceInfo::new(
            SERVICE_TYPE,
            &instance_name,
            &host_label,
            "",
            port,
            Some(props),
        )
        .map_err(|e| ChameyeError::Discovery(format!("service info failed: {e}")))?
        .enable_addr_auto();

        let fullname = service_info.get_fullname().to_string();
        self.daemon
            .register(service_info)
            .map_err(|e| ChameyeError::Discovery(format!("mdns register failed: {e}")))?;
        *self.registered_fullname.lock().unwrap() = Some(fullname);
        Ok(())
    }

    /// Start browsing for Chameye Hosts on the LAN in a background thread.
    pub fn start_browsing(&self, self_device_id: Option<String>) -> Result<()> {
        let receiver = self
            .daemon
            .browse(SERVICE_TYPE)
            .map_err(|e| ChameyeError::Discovery(format!("mdns browse failed: {e}")))?;
        let peers = Arc::clone(&self.peers);

        std::thread::spawn(move || {
            while let Ok(event) = receiver.recv() {
                match event {
                    ServiceEvent::ServiceResolved(info) => {
                        let props = info.get_properties();
                        let device_id = props
                            .get_property_val_str("id")
                            .unwrap_or_default()
                            .to_string();
                        if device_id.is_empty() {
                            continue;
                        }
                        if self_device_id.as_deref() == Some(device_id.as_str()) {
                            continue;
                        }
                        let device_name = props
                            .get_property_val_str("name")
                            .unwrap_or_else(|| info.get_fullname())
                            .to_string();
                        let os = props
                            .get_property_val_str("os")
                            .unwrap_or("unknown")
                            .to_string();
                        let protocol_version = props
                            .get_property_val_str("v")
                            .and_then(|v| v.parse::<u32>().ok())
                            .unwrap_or(1);
                        let addresses: Vec<IpAddr> = info.get_addresses().iter().copied().collect();
                        let peer = DiscoveredPeer {
                            device_id: device_id.clone(),
                            device_name,
                            os,
                            addresses,
                            port: info.get_port(),
                            protocol_version,
                        };
                        debug!("Discovered Chameye peer: {:?}", peer);
                        if let Ok(mut guard) = peers.lock() {
                            guard.insert(device_id, peer);
                        }
                    }
                    ServiceEvent::ServiceRemoved(_ty, fullname) => {
                        if let Ok(mut guard) = peers.lock() {
                            guard.retain(|_, p| !fullname.contains(&p.device_id[..p.device_id.len().min(8)]));
                        }
                    }
                    _ => {}
                }
            }
            warn!("mDNS browse loop exited");
        });

        Ok(())
    }

    pub fn list_peers(&self) -> Vec<DiscoveredPeer> {
        self.peers
            .lock()
            .map(|g| g.values().cloned().collect())
            .unwrap_or_default()
    }
}

impl Drop for DiscoveryService {
    fn drop(&mut self) {
        if let Some(fullname) = self.registered_fullname.lock().ok().and_then(|mut g| g.take()) {
            let _ = self.daemon.unregister(&fullname);
        }
        let _ = self.daemon.shutdown();
    }
}
