CREATE TABLE IF NOT EXISTS ormin_mysql_parent (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(200) NOT NULL,
  UNIQUE KEY uq_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS ormin_mysql_types (
  id BIGINT NOT NULL AUTO_INCREMENT,
  parent_id BIGINT,
  note LONGTEXT,
  payload LONGBLOB,
  signed_value BIGINT,
  unsigned_value BIGINT UNSIGNED,
  amount DECIMAL(30, 10),
  enabled BOOLEAN,
  tiny TINYINT(1),
  ratio DOUBLE,
  created DATETIME(6),
  stamp TIMESTAMP(6) NULL,
  day DATE,
  duration TIME(6),
  info JSON,
  state ENUM('new', 'done'),
  PRIMARY KEY (id),
  KEY ix_parent (parent_id),
  CONSTRAINT fk_mysql_parent FOREIGN KEY (parent_id) REFERENCES ormin_mysql_parent(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `ormin_mysql_Case` (
  `id` INT PRIMARY KEY,
  `select` VARCHAR(100)
) ENGINE=InnoDB;
