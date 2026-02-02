CREATE TABLE backup_runs (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    host VARCHAR(64) NOT NULL,
    service VARCHAR(64) NOT NULL,
    mode ENUM('backup','restore','merge','compare','dry') NOT NULL,

    status ENUM('success','failed','partial') NOT NULL,
    runtime_seconds INT UNSIGNED NOT NULL,

    diskusage_bytes BIGINT UNSIGNED NOT NULL,
    throughput_mb_s DECIMAL(8,2) NOT NULL,

    snapshot_name VARCHAR(128),
    started_at DATETIME NOT NULL,
    finished_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    KEY idx_host_service_time (host, service, started_at),
    KEY idx_status_time (status, started_at)
) ENGINE=InnoDB;

CREATE TABLE backup_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    run_id BIGINT UNSIGNED NOT NULL,

    level ENUM('info','warn','error') NOT NULL,
    message TEXT NOT NULL,
    source ENUM('script','state','applog') NOT NULL,

    created_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    KEY idx_run_level (run_id, level),
    CONSTRAINT fk_run
      FOREIGN KEY (run_id) REFERENCES backup_runs(id)
      ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE node_metrics (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    host VARCHAR(64) NOT NULL,
    service VARCHAR(64) NOT NULL,

    metric VARCHAR(64) NOT NULL,
    value BIGINT NOT NULL,

    collected_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    KEY idx_metric_time (service, metric, collected_at)
);

