/*M!999999\- enable the sandbox mode */
-- MariaDB dump 10.19  Distrib 10.6.24-MariaDB, for debian-linux-gnu (x86_64)
--
-- Host: localhost    Database: telemetry
-- ------------------------------------------------------
-- Server version	10.6.24-MariaDB-deb11-log

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Current Database: `telemetry`
--

CREATE DATABASE /*!32312 IF NOT EXISTS*/ `telemetry` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci */;

USE `telemetry`;

--
-- Table structure for table `backup_events`
--

DROP TABLE IF EXISTS `backup_events`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `backup_events` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `run_id` bigint(20) unsigned NOT NULL,
  `level` enum('info','warn','error') NOT NULL,
  `message` text NOT NULL,
  `source` enum('script','state','applog') NOT NULL,
  `created_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_run_level` (`run_id`,`level`),
  CONSTRAINT `fk_run` FOREIGN KEY (`run_id`) REFERENCES `backup_runs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `backup_events`
--

LOCK TABLES `backup_events` WRITE;
/*!40000 ALTER TABLE `backup_events` DISABLE KEYS */;
/*!40000 ALTER TABLE `backup_events` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `backup_runs`
--

DROP TABLE IF EXISTS `backup_runs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `backup_runs` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `host` varchar(64) NOT NULL,
  `service` varchar(64) NOT NULL,
  `mode` enum('backup','restore','merge','compare','dry') NOT NULL,
  `status` enum('success','failed','partial') NOT NULL,
  `runtime_seconds` int(10) unsigned NOT NULL,
  `diskusage_bytes` bigint(20) unsigned NOT NULL,
  `throughput_mb_s` decimal(8,2) NOT NULL,
  `snapshot_name` varchar(128) DEFAULT NULL,
  `started_at` datetime NOT NULL,
  `finished_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_host_service_time` (`host`,`service`,`started_at`),
  KEY `idx_status_time` (`status`,`started_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `backup_runs`
--

LOCK TABLES `backup_runs` WRITE;
/*!40000 ALTER TABLE `backup_runs` DISABLE KEYS */;
/*!40000 ALTER TABLE `backup_runs` ENABLE KEYS */;
UNLOCK TABLES;

--
-- Table structure for table `node_metrics`
--

DROP TABLE IF EXISTS `node_metrics`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `node_metrics` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `host` varchar(64) NOT NULL,
  `service` varchar(64) NOT NULL,
  `metric` varchar(64) NOT NULL,
  `value` bigint(20) NOT NULL,
  `collected_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_metric_time` (`service`,`metric`,`collected_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `node_metrics`
--

LOCK TABLES `node_metrics` WRITE;
/*!40000 ALTER TABLE `node_metrics` DISABLE KEYS */;
/*!40000 ALTER TABLE `node_metrics` ENABLE KEYS */;
UNLOCK TABLES;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-02-02 23:26:08
