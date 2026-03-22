#!/usr/bin/env bash
# ============================================================
# Funghi Map — Build, push to ECR, and deploy to ECS Fargate
#
# Usage:
#   make deploy                                 # deploy both api + worker
#   make deploy-api                             # deploy api service only
#   make deploy-worker                          # update worker task def only
#
# Required env vars:
#   AWS_ACCOUNT_ID   — AWS account ID
#   AWS_REGION       — AWS region (default: eu-south-1)
#   ENVIRONMENT      — staging or production (default: production)
# ============================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-south-1}"
ENVIRONMENT="${ENVIRONMENT:-production}"
IMAGE_NAME="funghi-map"
CLUSTER="funghi-map-${ENVIRONMENT}"
API_SERVICE="funghi-map-api"

if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    echo "ERROR: AWS_ACCOUNT_ID is required"
    exit 1
fi

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}"
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
IMAGE_TAG="${GIT_SHA}"

DEPLOY_API=true
DEPLOY_WORKER=true

case "${1:-}" in
    --api-only)    DEPLOY_WORKER=false ;;
    --worker-only) DEPLOY_API=false ;;
esac

echo "=== Funghi Map Deploy ==="
echo "  Region:      ${AWS_REGION}"
echo "  Environment: ${ENVIRONMENT}"
echo "  Image:       ${ECR_URI}:${IMAGE_TAG}"
echo ""

# ── Step 1: ECR Login ────────────────────────────────────
echo "▶ Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ── Step 2: Build Docker image ───────────────────────────
echo "▶ Building Docker image..."
docker build \
    --platform linux/amd64 \
    -f infra/docker/Dockerfile \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -t "${IMAGE_NAME}:latest" \
    .

# ── Step 3: Tag and push to ECR ─────────────────────────
echo "▶ Pushing to ECR..."
docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker tag "${IMAGE_NAME}:latest" "${ECR_URI}:latest"
docker push "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:latest"

# ── Step 4: Update ECS task definitions ──────────────────
update_task_def() {
    local family="$1"
    local template="$2"

    echo "▶ Updating task definition: ${family}..."
    local task_def
    task_def=$(sed "s|ACCOUNT_ID|${AWS_ACCOUNT_ID}|g" "${template}" | \
               jq --arg img "${ECR_URI}:${IMAGE_TAG}" \
                  '.containerDefinitions[0].image = $img')

    aws ecs register-task-definition \
        --region "${AWS_REGION}" \
        --cli-input-json "${task_def}" \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text
}

if [ "${DEPLOY_API}" = true ]; then
    API_TASK_ARN=$(update_task_def "funghi-map-api" "infra/ecs/task-def-api.json")
    echo "  Registered: ${API_TASK_ARN}"
fi

if [ "${DEPLOY_WORKER}" = true ]; then
    WORKER_TASK_ARN=$(update_task_def "funghi-map-worker" "infra/ecs/task-def-worker.json")
    echo "  Registered: ${WORKER_TASK_ARN}"
fi

# ── Step 5: Force new deployment on API service ──────────
if [ "${DEPLOY_API}" = true ]; then
    echo "▶ Deploying API service..."
    aws ecs update-service \
        --region "${AWS_REGION}" \
        --cluster "${CLUSTER}" \
        --service "${API_SERVICE}" \
        --task-definition "${API_TASK_ARN}" \
        --force-new-deployment \
        --query 'service.serviceName' \
        --output text

    echo "▶ Waiting for API deployment to stabilize..."
    aws ecs wait services-stable \
        --region "${AWS_REGION}" \
        --cluster "${CLUSTER}" \
        --services "${API_SERVICE}"
fi

echo ""
echo "=== Deploy complete ==="
echo "  API task:    ${API_TASK_ARN:-skipped}"
echo "  Worker task: ${WORKER_TASK_ARN:-skipped}"
