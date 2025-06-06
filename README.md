# Server Migration Tools

A collection of shell scripts for migrating web applications and services between servers, with a focus on PostgreSQL databases, Nginx configurations, and related services.

## Overview

This toolkit provides scripts for:

- Database migration (PostgreSQL)
- Nginx configuration migration and repair
- System service management (uwsgi, Celery, Redis, RabbitMQ)
- Core migration utilities

## Scripts

### 1. `core.sh`

Core migration utilities and functions.

**Key Features:**

- Server-to-server file synchronization
- Nginx configuration migration
- uwsgi service management
- Environment setup

**Usage:**

```bash
./core.sh [options]
```

### 2. `db_migration.sh`

PostgreSQL database migration script.

**Key Features:**

- Database version compatibility checks
- Direct table and data copying
- Automatic database creation
- Error handling and validation

**Usage:**

```bash
./db_migration.sh [source_host] [source_port] [source_user] [dest_host] [dest_port] [dest_user]
```

### 3. `install_postgres.sh`

PostgreSQL installation and configuration script.

**Key Features:**

- PostgreSQL installation
- Configuration setup
- User management
- Database initialization

**Usage:**

```bash
./install_postgres.sh [version]
```

### 4. `migration.sh`

Main migration coordination script.

**Key Features:**

- Orchestrates the migration process
- Coordinates between different scripts
- Handles dependencies
- Progress tracking

**Usage:**

```bash
./migration.sh [options]
```

### 5. `nginx.sh`

Nginx configuration repair and module management.

**Key Features:**

- Configuration validation
- Module detection and repair
- Symlink management
- Service monitoring

**Usage:**

```bash
./nginx.sh [repair|check|status]
```

## Prerequisites

- SSH access to both source and destination servers
- Root or sudo privileges
- PostgreSQL installed on both servers
- Nginx installed on both servers

## Configuration

1. Edit source and destination server details in `core.sh`:

```bash
SOURCE_HOST="your_source_host"
SOURCE_USER="your_source_user"
SOURCE_PORT="22"
```

1. Set up SSH keys for passwordless authentication
1. Ensure all required services are installed on both servers

## Common Use Cases

1. **Full Migration**

```bash
./migration.sh --full
```

1. **Database Only Migration**

```bash
./db_migration.sh
```

1. **Nginx Configuration Repair**

```bash
./nginx.sh repair
```

## How to Configure PostgreSQL 12 on Ubuntu to Accept Worldwide Connections

### 1. Edit `postgresql.conf`

Open the PostgreSQL configuration file:

```bash
sudo nano /etc/postgresql/12/main/postgresql.conf
```

Find the following line:

```conf
#listen_addresses = 'localhost'
```

Change it to:

```conf
listen_addresses = '*'
```

### 2. Edit `pg_hba.conf`

Open the client authentication file:

```bash
sudo nano /etc/postgresql/12/main/pg_hba.conf
```

Add the following line at the end to allow all IPs to connect:

```conf
host    all             all             0.0.0.0/0               md5
```

_Note: Use `scram-sha-256` if your setup uses more secure authentication._

### 3. Restart PostgreSQL

Apply changes by restarting the PostgreSQL service:

```bash
sudo systemctl restart postgresql
```

### 4. Allow PostgreSQL Port Through Firewall

If using UFW:

```bash
sudo ufw allow 5432/tcp
```

### 5. Optional: Confirm Listening

Check if PostgreSQL is listening on port 5432:

```bash
sudo netstat -tuln | grep 5432
```

Or:

```bash
ss -tuln | grep 5432
```

### ⚠️ Security Warning

Opening PostgreSQL to the whole world (`0.0.0.0/0`) is **not recommended** for production without:

- Strong passwords or certificate-based auth
- IP whitelisting or VPN
- Encrypted connections (TLS/SSL)

Restrict to known IPs if possible.

## Error Handling

- All scripts include error logging
- Check logs in `/var/log/` for detailed error messages
- Use `--verbose` flag for detailed output

## Best Practices

1. Always backup before migration
2. Test in staging environment first
3. Verify service status after migration
4. Monitor logs during migration process

## Troubleshooting

Common issues and solutions:

1. Permission denied: Ensure proper SSH key setup
2. Service not starting: Check logs and configurations
3. Database connection failed: Verify credentials and firewall rules

## Contributing

1. Fork the repository
2. Create your feature branch
3. Submit a pull request

## License

MIT License - See LICENSE file for details
