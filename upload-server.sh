#!/bin/bash
set -e  # Stop the script if there are any errors

# Default values
ENV_FILE=""
DOCKER_COMPOSE_FILE="docker-compose.yml"
GIT_BRANCH=""
HEALTH_URL=""
ENVIRONMENT_NAME=""
REBUILD=false
RERUN_ONLY=false
CLEAR_CACHE=false

# Display usage instructions
show_usage() {
    echo "Usage: $0 -e ENV_FILE [options]"
    echo "Required:"
    echo "  -e FILE     Environment file path (e.g., .env.prod, .env.perf)"
    echo ""
    echo "Options:"
    echo "  -f FILE     Docker Compose file path (default: docker-compose.yml)"
    echo "  -g BRANCH   Git branch to pull (default: auto-detect from env)"
    echo "  -u URL      Health check URL (default: auto-detect from env)"
    echo "  -n NAME     Environment name for display (default: auto-detect)"
    echo "  -b          Rebuild containers from scratch"
    echo "  -r          Restart only without rebuild"
    echo "  -c          Clear Docker cache and rebuild completely"
    echo "  -h          Show usage instructions"
    echo ""
    echo "Examples:"
    echo "  $0 -e .env.prod                    # Production deployment"
    echo "  $0 -e .env.perf -b                # Performance env with rebuild"
    echo "  $0 -e .env.dev -r                 # Development restart only"
    echo "  $0 -e .env.qa -f docker-compose.qa.yml  # QA with custom compose file"
    echo "  $0 -e .env.stage -g staging -u https://stage.kupath.click/health"
}

# Parse parameters
while getopts "e:f:g:u:n:brch" option; do
    case $option in
        e)
            ENV_FILE="$OPTARG"
            ;;
        f)
            DOCKER_COMPOSE_FILE="$OPTARG"
            ;;
        g)
            GIT_BRANCH="$OPTARG"
            ;;
        u)
            HEALTH_URL="$OPTARG"
            ;;
        n)
            ENVIRONMENT_NAME="$OPTARG"
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
            echo "Unknown option: $option"
            show_usage
            exit 1
            ;;
    esac
done

# Check that ENV file is required
if [ -z "$ENV_FILE" ]; then
    echo "❌ Error: Environment file is required. Use -e option."
    show_usage
    exit 1
fi

# Ensure no conflicting parameters
if [ "$REBUILD" = true ] && [ "$RERUN_ONLY" = true ]; then
    echo "❌ Error: Cannot use -b and -r together"
    exit 1
fi

# Check that ENV file exists
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: Environment file '$ENV_FILE' not found!"
    exit 1
fi

# Check that Docker Compose file exists
if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    echo "❌ Error: Docker Compose file '$DOCKER_COMPOSE_FILE' not found!"
    exit 1
fi

# Load environment variables for auto-detection
set -a  # Automatically export all variables
# Load env file with proper handling for Linux
if [ -f "$ENV_FILE" ]; then
    # Remove carriage returns and source the file properly
    export $(grep -v '^#' "$ENV_FILE" | tr -d '\r' | xargs)
fi
set +a

# Auto-detect parameters from environment file
if [ -z "$ENVIRONMENT_NAME" ]; then
    # Try to detect environment name from file
    if [[ "$ENV_FILE" == *"prod"* ]]; then
        ENVIRONMENT_NAME="Production"
    elif [[ "$ENV_FILE" == *"perf"* ]]; then
        ENVIRONMENT_NAME="Performance"
    elif [[ "$ENV_FILE" == *"dev"* ]]; then
        ENVIRONMENT_NAME="Development"
    elif [[ "$ENV_FILE" == *"qa"* ]]; then
        ENVIRONMENT_NAME="QA"
    elif [[ "$ENV_FILE" == *"stage"* ]]; then
        ENVIRONMENT_NAME="Staging"
    else
        ENVIRONMENT_NAME="Unknown"
    fi
fi

if [ -z "$GIT_BRANCH" ]; then
    # Try to detect branch from environment file or name
    if [ ! -z "$DEPLOY_BRANCH" ]; then
        GIT_BRANCH="$DEPLOY_BRANCH"
    elif [[ "$ENV_FILE" == *"prod"* ]]; then
        GIT_BRANCH="main"
    elif [[ "$ENV_FILE" == *"perf"* ]]; then
        GIT_BRANCH="performance"
    elif [[ "$ENV_FILE" == *"dev"* ]]; then
        GIT_BRANCH="develop"
    else
        GIT_BRANCH="main"
    fi
fi

if [ -z "$HEALTH_URL" ]; then
    # Try to detect Health URL from environment file
    if [ ! -z "$HEALTH_CHECK_URL" ]; then
        HEALTH_URL="$HEALTH_CHECK_URL"
    elif [ ! -z "$BASE_URL" ]; then
        HEALTH_URL="$BASE_URL/health"
    else
        # Default by environment
        if [[ "$ENV_FILE" == *"prod"* ]]; then
            HEALTH_URL="https://kupath.click/health"
        elif [[ "$ENV_FILE" == *"perf"* ]]; then
            HEALTH_URL="https://perf.kupath.click/health"
        elif [[ "$ENV_FILE" == *"dev"* ]]; then
            HEALTH_URL="https://dev.kupath.click/health"
        else
            HEALTH_URL="http://localhost/health"
        fi
    fi
fi

echo "🚀 Starting deployment to $ENVIRONMENT_NAME environment..."
echo "📄 Environment file: $ENV_FILE"
echo "🐳 Docker Compose file: $DOCKER_COMPOSE_FILE"
echo "🌿 Git branch: $GIT_BRANCH"
echo "🏥 Health URL: $HEALTH_URL"

# Step 1: Update from Git (skip if restart only)
if [ "$RERUN_ONLY" = false ]; then
    echo "🔄 Pulling latest code from Git branch: $GIT_BRANCH..."
    git pull origin "$GIT_BRANCH"
fi

# Step 2: General checks
echo "🧩 Checking server health..."
df -h
free -h

# Step 3: Stop existing containers
echo "🛑 Stopping existing containers..."
docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" down || true

# Step 4: Docker cleanup (conditional)
if [ "$CLEAR_CACHE" = true ]; then
    echo "🧹 Clearing Docker cache completely..."
    docker system prune -a -f --volumes
    echo "🗑️ Removing unused images..."
    docker image prune -a -f
elif [ "$REBUILD" = true ]; then
    echo "🧹 Cleaning old Docker resources..."
    docker system prune -f
fi

echo "🔧 Deploying to $ENVIRONMENT_NAME environment..."

echo "🗄️ Database: $DATABASE_CONNECTION_STRING"

# Check configuration before running
echo "🔍 Checking Docker Compose configuration..."
docker-compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" config > /dev/null
if [ $? -ne 0 ]; then
    echo "❌ Docker Compose configuration error!"
    exit 1
fi

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

# Wait for containers to start
echo "⏳ Waiting for containers to start..."
sleep 30

echo "✅ $ENVIRONMENT_NAME deployment completed!"

# Status check
echo "📊 Container status:"
docker ps

# Detailed diagnosis
echo ""
echo "🔍 Detailed diagnosis..."

# Container list - can be defined in ENV file or default
CONTAINERS="kupat-hair-user-server kupat-hair-external-api kupat-hair-management-server nginx-proxy"
if [ ! -z "$CONTAINER_NAMES" ]; then
    CONTAINERS="$CONTAINER_NAMES"
fi

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

# Port check - can be defined in ENV file
PORTS="8081 8082 8083"
if [ ! -z "$CHECK_PORTS" ]; then
    PORTS="$CHECK_PORTS"
fi

echo "=== Port Check ==="
for port in $PORTS; do
    echo "Checking port $port..."
    if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        echo "  ✅ Port $port is bound on host"
    else
        echo "  ❌ Port $port is not bound on host"
    fi
done

# Health endpoint check
if docker inspect --format='{{.State.Status}}' nginx-proxy 2>/dev/null | grep -q "running"; then
    echo ""
    echo "=== Health Check Test ==="
    
    # Additional wait for services to fully start
    echo "Waiting additional 30 seconds for services to initialize..."
    sleep 30
    
    # Check through nginx
    echo "Testing health endpoint: $HEALTH_URL"
    if timeout 10 curl -f -s "$HEALTH_URL" >/dev/null 2>&1; then
        echo "  ✅ Health endpoint is responding"
    else
        echo "  ❌ Health endpoint is not responding"
        echo "  📝 Nginx error logs:"
        docker logs nginx-proxy 2>&1 | tail -10 | sed 's/^/    /'
    fi
fi

echo ""
echo "🏁 Diagnosis completed!"
echo "🌐 Try accessing: $HEALTH_URL"