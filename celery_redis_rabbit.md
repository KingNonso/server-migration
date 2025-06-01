# Setting Up Celery, Redis, and RabbitMQ on Ubuntu

This guide provides step-by-step instructions for setting up Celery with Redis and RabbitMQ on an Ubuntu server. All installation commands include the `-y` flag to automate the setup process without requiring user confirmation.

## Table of Contents
1. [Installing RabbitMQ (Message Broker)](#installing-rabbitmq)
2. [Installing Redis (Result Backend)](#installing-redis)
3. [Setting Up Celery](#setting-up-celery)

## Installing RabbitMQ

RabbitMQ serves as the message broker for Celery tasks.

```bash
# Update package index and install RabbitMQ
sudo apt update -y
sudo apt install -y rabbitmq-server

# Enable and start the RabbitMQ service
sudo systemctl enable rabbitmq-server
sudo systemctl start rabbitmq-server

# Verify the service is running
sudo systemctl status rabbitmq-server
```

### Enable RabbitMQ Management Dashboard (Optional)

```bash
# Enable the management plugin
sudo rabbitmq-plugins enable rabbitmq_management
```

You can access the dashboard at `http://your_server_ip:15672` with the following default credentials:
- Username: `guest`
- Password: `guest`

> **Note**: The default credentials only work when accessing from localhost. For remote access, you should create a new admin user.

### Creating an Admin User (Recommended for Production)

```bash
# Create admin user (replace username and password)
sudo rabbitmqctl add_user admin strong_password
sudo rabbitmqctl set_user_tags admin administrator
sudo rabbitmqctl set_permissions -p / admin ".*" ".*" ".*"
```

## Installing Redis

Redis is commonly used as a result backend for Celery to store task results.

```bash
# Update package index and install Redis
sudo apt update -y
sudo apt install -y redis-server

# Enable and start the Redis service
sudo systemctl enable redis-server
sudo systemctl start redis-server

# Verify the service is running
sudo systemctl status redis-server
```

### Configure Redis for Systemd Supervision

```bash
# Edit the Redis configuration file
sudo sed -i 's/supervised no/supervised systemd/g' /etc/redis/redis.conf

# Restart Redis to apply changes
sudo systemctl restart redis-server
```

### Test Redis Functionality

```bash
# Test if Redis is responding properly
redis-cli ping
```

You should receive `PONG` as the response if Redis is working correctly.

## Setting Up Celery

### 1. Create Required Directories for Logs and PIDs

```bash
# Create directories for Celery logs and PIDs
sudo mkdir -p /var/run/celery /var/log/celery

# Set proper permissions (adjust user:group as needed for your application)
sudo chown -R root:root /var/run/celery /var/log/celery
sudo chmod -R 755 /var/run/celery /var/log/celery
```

### 2. Create the Celery Environment File

Create the environment file at `/etc/default/celery` (Ubuntu's equivalent to `/etc/sysconfig/celery`):

```bash
# Create the environment file
sudo tee /etc/default/celery > /dev/null << 'EOF'
# Name of nodes to start
CELERYD_NODES="worker1"

# Absolute path to the 'celery' command
CELERY_BIN="/root/peddlesoftnext/venv/bin/celery"

# App instance to use
CELERY_APP="peddlesoftnext"

# Worker options
CELERYD_OPTS="--time-limit=300 --concurrency=4"

# %n will be replaced with the first part of the nodename
CELERYD_LOG_FILE="/var/log/celery/%n.log"
CELERYD_PID_FILE="/var/run/celery/%n.pid"

# Log level
CELERYD_LOG_LEVEL="INFO"
EOF
```

### 3. Create the Celery Service File

Create a systemd service file for Celery:

```bash
# Create the systemd service file
sudo tee /etc/systemd/system/celery.service > /dev/null << 'EOF'
[Unit]
Description=Celery Service
After=network.target redis-server.service rabbitmq-server.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root/peddlesoftnext
ExecStart=/root/peddlesoftnext/venv/bin/celery -A peddlesoftnext worker --loglevel=INFO --logfile=/var/log/celery/worker.log
Restart=always

[Install]
WantedBy=multi-user.target
EOF
```

### 4. Enable and Start the Celery Service

```bash
# Reload systemd configurations
sudo systemctl daemon-reload

# Enable Celery service to start at boot
sudo systemctl enable celery.service

# Start the Celery service
sudo systemctl start celery.service

# Verify the service is running
sudo systemctl status celery.service
```

## Troubleshooting

### Viewing Celery Logs

```bash
sudo tail -f /var/log/celery/worker.log
```

### Checking Service Status

```bash
# For RabbitMQ
sudo systemctl status rabbitmq-server

# For Redis
sudo systemctl status redis-server

# For Celery
sudo systemctl status celery.service
```

### Restarting Services

```bash
# Restart all services
sudo systemctl restart rabbitmq-server redis-server celery.service
```

---

## Configuration Notes

- Adjust all paths according to your project structure
- For production environments, consider setting up a dedicated user instead of using root
- Configure proper firewall rules if these services need to be accessed remotely
