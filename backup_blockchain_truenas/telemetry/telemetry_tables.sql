
CREATE TABLE blockchain_backup_runs (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    ts            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    host          VARCHAR(64)  NOT NULL,
    service       VARCHAR(32)  NOT NULL,
    mode          VARCHAR(16)  NOT NULL,

    runtime_s     INT UNSIGNED,
    exit_code     INT,

    src_size_b    BIGINT UNSIGNED,
    dst_size_b    BIGINT UNSIGNED,

    snapshot      VARCHAR(128),

    INDEX idx_ts (ts),
    INDEX idx_host_service (host, service)
);

CREATE TABLE blockchain_backup_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    run_id BIGINT UNSIGNED NOT NULL,

    level ENUM('log','warn','error','fatal') NOT NULL,
    message TEXT NOT NULL,
    source ENUM('script','state','applog') NOT NULL,

    created_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    KEY idx_run_level (run_id, level),
    CONSTRAINT fk_run
      FOREIGN KEY (run_id)
      REFERENCES blockchain_backup_runs(id)
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

