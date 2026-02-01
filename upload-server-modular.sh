#!/bin/bash
set -e  # Stop the script if there are any errors

# Default values
ENVIRONMENT=""
REBUILD=false
RERUN_ONLY=false
CLEAR_CACHE=false

# Display usage instructions
show_usage() {
    echo "Usage: $0 -e ENVIRONMENT [options]"
    echo ""
    echo "Required:"
    echo "  -e NAME     Environment name (e.g., prod, release, perf, dev, qa, stage)"
    echo "              Will automatically use:"
    echo "                - {NAME}.env"
    echo "                - docker-compose.{NAME}.yml"
    echo "                - Git branch from DEPLOY_BRANCH in env file"
    echo ""
    echo "Options:"
    echo "  -b          Rebuild containers from scratch"
    echo "  -r          Restart only without rebuild"
    echo "  -c          Clear Docker cache and rebuild completely"
    echo "  -h          Show usage instructions"
    echo ""
    echo "Examples:"
    echo "  $0 -e prod                      # Deploy production"
    echo "  $0 -e release -b                # Deploy release with rebuild"
    echo "  $0 -e dev -r                    # Restart development only"
    echo "  $0 -e perf -c                   # Performance with cache clear"
    echo ""
    echo "Environment file ({NAME}.env) should contain:"
    echo "  DEPLOY_BRANCH=main              # Git branch to deploy"
    echo "  ENVIRONMENT_NAME=Production     # Display name"
    echo "  HEALTH_CHECK_URL=https://...    # Health endpoint URL"
    echo "  BASE_URL=https://...            # Base URL (fallback for health)"
    echo "  CONTAINER_NAMES=\"cont1 cont2\"   # Optional: containers to check"
    echo "  CHECK_PORTS=\"8081 8082\"         # Optional: ports to verify"
    echo "  PROXY_CONTAINER=nginx-proxy     # Optional: proxy container name"
}

# Parse parameters
while getopts "e:brch" option; do
    case $option in
        e)
            ENVIRONMENT="$OPTARG"
            ;;
        b)
            REBUILD=true
            ;;
        r)
            RERUN_ONLY=true
            ;;
        c)
            CLEAR_CACHE=true
            REBUILD=true  # Cache cleanup includes rebuild
            ;;
        h)
            show_usage
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $option"
            show_usage
            exit 1
            ;;
    esac
done

# Check that environment is required
if [ -z "$ENVIRONMENT" ]; then
    echo "❌ Error: Environment name is required. Use -e option."
    echo ""
    show_usage
    exit 1
fi

# Ensure no conflicting parameters
if [ "$REBUILD" = true ] && [ "$RERUN_ONLY" = true ]; then
    echo "❌ Error: Cannot use -b and -r together"
    exit 1
fi

# Build file paths from environment name
ENV_FILE="${ENVIRONMENT}.env"
DOCKER_COMPOSE_FILE="docker-compose.${ENVIRONMENT}.yml"

# Check that ENV file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: Environment file '$ENV_FILE' not found!"
    echo "💡 Create this file with your environment configuration."
    exit 1
fi

# Check that Docker Compose file exists
if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    echo "❌ Error: Docker Compose file '$DOCKER_COMPOSE_FILE' not found!"
    exit 1
fi

# Load environment variables
# Using source with proper handling for values with spaces and special chars
if [ -f "$ENV_FILE" ]; then
    # Remove carriage returns and source the file safely
    set -a  # Automatically export all variables
    source <(grep -v '^#' "$ENV_FILE" | sed '/^\s*$/d' | tr -d '\r')
    set +a
fi

# Extract configuration from environment file with smart defaults
GIT_BRANCH="${DEPLOY_BRANCH:-$ENVIRONMENT}"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-$ENVIRONMENT}"
HEALTH_URL="${HEALTH_CHECK_URL}"

# If no health URL, try to build from BASE_URL
if [ -z "$HEALTH_URL" ] && [ ! -z "$BASE_URL" ]; then
    HEALTH_URL="${BASE_URL}/health"
fi

# Final fallback for health URL
if [ -z "$HEALTH_URL" ]; then
    HEALTH_URL="http://localhost/health"
    echo "⚠️  Warning: No HEALTH_CHECK_URL or BASE_URL defined, using default: $HEALTH_URL"
fi

# Container names - use from env or default
CONTAINERS="${CONTAINER_NAMES:-kupat-hair-user-server kupat-hair-external-api kupat-hair-management-server nginx-proxy}"

# Proxy container name - use from env or default
PROXY_CONTAINER="${PROXY_CONTAINER:-nginx-proxy}"

# Ports to check - use from env or default
PORTS="${CHECK_PORTS:-8081 8082 8083}"

echo "🚀 Starting deployment to $ENVIRONMENT_NAME environment..."
echo "📄 Environment file: $ENV_FILE"
echo "🐳 Docker Compose file: $DOCKER_COMPOSE_FILE"
echo "🌿 Git branch: $GIT_BRANCH"
echo "🏥 Health URL: $HEALTH_URL"
echo ""

# Step 1: Update from Git (skip if restart only)
if [ "$RERUN_ONLY" = false ]; then
    echo "🔄 Pulling latest code from Git branch: $GIT_BRANCH..."
    git pull origin "$GIT_BRANCH"
    echo ""
fi

# Step 2: System health checks
echo "🧩 Checking server health..."
df -h
free -h
echo ""

# Step 3: Stop existing containers
echo "🛑 Stopping existing containers..."
docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" down --remove-orphans || true
echo ""

# Step 4: Docker cleanup (conditional)
if [ "$CLEAR_CACHE" = true ]; then
    echo "🧹 Clearing Docker cache completely..."
    docker system prune -a -f --volumes
    echo "🗑️ Removing unused images..."
    docker image prune -a -f
    echo ""
elif [ "$REBUILD" = true ]; then
    echo "🧹 Cleaning old Docker resources..."
    docker system prune -f
    echo ""
fi

echo "🔧 Deploying to $ENVIRONMENT_NAME environment..."

# Show database connection (first 50 chars for security)
if [ ! -z "$DATABASE_CONNECTION_STRING" ]; then
    echo "🗄️ Database: ${DATABASE_CONNECTION_STRING:0:50}..."
fi
echo ""

# Check configuration before running
echo "🔍 Checking Docker Compose configuration..."
docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" config > /dev/null
if [ $? -ne 0 ]; then
    echo "❌ Docker Compose configuration error!"
    exit 1
fi
echo ""

# Execution logic by parameters
if [ "$RERUN_ONLY" = true ]; then
    echo "🔄 Restarting containers only (no rebuild)..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" up -d
elif [ "$REBUILD" = true ] || [ "$CLEAR_CACHE" = true ]; then
    echo "🔨 Force rebuilding containers..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" build --no-cache
    echo "🚀 Starting containers..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" up -d
else
    echo "🔨 Building containers..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" build
    echo "🚀 Starting containers..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" up -d
fi
echo ""

# Wait for containers to start
echo "⏳ Waiting for containers to start..."
sleep 30
echo ""

echo "✅ $ENVIRONMENT_NAME deployment completed!"
echo ""

# Status check
echo "📊 Container status:"
docker ps
echo ""

# Detailed diagnosis
echo "🔍 Detailed diagnosis..."
echo ""

# Container status check
echo "=== Container Status Details ==="
for container in $CONTAINERS; do
    echo "Checking $container..."

    if docker inspect $container >/dev/null 2>&1; then
        STATUS=$(docker inspect --format='{{.State.Status}}' $container)
        HEALTH=$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null || echo "no-healthcheck")
        RESTART_COUNT=$(docker inspect --format='{{.RestartCount}}' $container)

        echo "  Status: $STATUS"
        echo "  Health: $HEALTH"
        echo "  Restart Count: $RESTART_COUNT"

        if [ "$STATUS" != "running" ]; then
            echo "  📝 Container logs (last 20 lines):"
            docker logs --tail=20 $container 2>&1 | sed 's/^/    /'
        fi
    else
        echo "  ❌ Container does not exist"
    fi
    echo ""
done

# Port check
echo "=== Port Check ==="
for port in $PORTS; do
    echo "Checking port $port..."
    if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        echo "  ✅ Port $port is bound on host"
    else
        echo "  ❌ Port $port is not bound on host"
    fi
done
echo ""

# Health endpoint check
if docker inspect --format='{{.State.Status}}' "$PROXY_CONTAINER" 2>/dev/null | grep -q "running"; then
    echo "=== Health Check Test ==="

    # Additional wait for services to fully start
    echo "Waiting additional 30 seconds for services to initialize..."
    sleep 30

    # Check through proxy
    echo "Testing health endpoint: $HEALTH_URL"
    if timeout 10 curl -f -s "$HEALTH_URL" >/dev/null 2>&1; then
        echo "  ✅ Health endpoint is responding"
    else
        echo "  ❌ Health endpoint is not responding"
        echo "  📝 Proxy container ($PROXY_CONTAINER) error logs:"
        docker logs "$PROXY_CONTAINER" 2>&1 | tail -10 | sed 's/^/    /'
    fi
    echo ""
fi

echo "🏁 Diagnosis completed!"
echo "🌐 Try accessing: $HEALTH_URL"
