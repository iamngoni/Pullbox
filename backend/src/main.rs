//! Runs the Pullbox HTTP service and wires optional APNs dependencies once per process.

use actix_cors::Cors;
use actix_web::{middleware::Logger, web, App, HttpServer};
use pullbox_backend::{
    apns::{
        ActivityNotifierHandle, ApnsActivityNotifier, ApnsClient, ApnsConfig,
        DisabledActivityNotifier, ReqwestApnsTransport, TokenRegistry,
    },
    configure,
};
use std::{io, sync::Arc};

#[actix_web::main]
async fn main() -> io::Result<()> {
    env_logger::init_from_env(env_logger::Env::new().default_filter_or("info"));
    let bind = std::env::var("PULLBOX_BIND").unwrap_or_else(|_| "0.0.0.0:8787".to_string());
    let token_store_path = std::env::var("PULLBOX_APNS_TOKEN_STORE_PATH")
        .unwrap_or_else(|_| "./data/live-activity-tokens.json".to_string());
    let registry = TokenRegistry::persistent(&token_store_path)
        .map_err(|error| io::Error::other(error.to_string()))?;
    let notifier =
        match ApnsConfig::from_env().map_err(|error| io::Error::other(error.to_string()))? {
            Some(config) => {
                let transport = Arc::new(ReqwestApnsTransport::new().map_err(io::Error::other)?);
                let client = Arc::new(ApnsClient::new(config, transport));
                log::info!("APNs Live Activity notifications enabled");
                ActivityNotifierHandle::new(Arc::new(ApnsActivityNotifier::new(
                    registry.clone(),
                    client,
                )))
            }
            None => {
                log::info!("APNs Live Activity notifications disabled");
                ActivityNotifierHandle::new(Arc::new(DisabledActivityNotifier))
            }
        };
    let registry = web::Data::new(registry);
    let notifier = web::Data::new(notifier);
    log::info!("Pullbox listening on http://{bind}");

    HttpServer::new(move || {
        App::new()
            .app_data(registry.clone())
            .app_data(notifier.clone())
            .wrap(Logger::default())
            .wrap(Cors::permissive())
            .configure(configure)
    })
    .bind(bind)?
    .run()
    .await
}
