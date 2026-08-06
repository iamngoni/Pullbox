use actix_cors::Cors;
use actix_web::{App, HttpServer, middleware::Logger};
use pullbox_backend::configure;

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init_from_env(env_logger::Env::new().default_filter_or("info"));
    let bind = std::env::var("PULLBOX_BIND").unwrap_or_else(|_| "0.0.0.0:8787".to_string());
    log::info!("Pullbox listening on http://{bind}");

    HttpServer::new(|| {
        App::new()
            .wrap(Logger::default())
            .wrap(Cors::permissive())
            .configure(configure)
    })
    .bind(bind)?
    .run()
    .await
}
