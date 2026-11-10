#!/usr/bin/env bash
# Deploy one image to one ECS service, then check that the deployment really worked.
#
# Usage: deploy-ecs-service.sh <cluster> <service> <container-name> <image-uri> <desired-count>
#
# What it does:
#   1. take the task definition the service runs now
#   2. copy it with the container's image replaced  -> new task definition revision
#   3. point the service at the new revision (rolling update, health checked by the ALB)
#   4. wait until the service is stable, then verify that it is NOT a rollback
set -euo pipefail

CLUSTER=$1
SERVICE=$2
CONTAINER=$3
IMAGE=$4
DESIRED=$5

WORK=$(mktemp -d)

show_events() {
  echo "---- last service events ----"
  aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].events[:8].[createdAt,message]' --output text || true
}
trap 'rm -rf "$WORK"' EXIT
trap 'show_events' ERR

CURRENT=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)
echo "[$SERVICE] current task definition: $CURRENT"

aws ecs describe-task-definition --task-definition "$CURRENT" \
  --query taskDefinition --output json > "$WORK/current.json"

# remove the fields AWS fills in itself, and set the new image on our container
jq --arg c "$CONTAINER" --arg img "$IMAGE" '
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
      .registeredAt, .registeredBy, .deregisteredAt)
  | .containerDefinitions |= map(if .name == $c then .image = $img else . end)
' "$WORK/current.json" > "$WORK/new.json"

NEW=$(aws ecs register-task-definition --cli-input-json "file://$WORK/new.json" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "[$SERVICE] registered:               $NEW"
echo "[$SERVICE] image:                    $IMAGE"

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$NEW" --desired-count "$DESIRED" > /dev/null
echo "[$SERVICE] rolling update started, waiting for it to become stable (max ~10 min) ..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"

# A failed deployment is rolled back by the circuit breaker, and then the service is "stable" too.
# So check which task definition the service runs now.
ACTIVE=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)
if [ "$ACTIVE" != "$NEW" ]; then
  echo "FAILED: the service went back to $ACTIVE (rolled back)."
  false
fi

TG=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].loadBalancers[0].targetGroupArn' --output text)
HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
echo "[$SERVICE] healthy targets in the load balancer: $HEALTHY (wanted: $DESIRED)"
if [ "$HEALTHY" -lt "$DESIRED" ]; then
  echo "FAILED: not enough healthy targets."
  false
fi

echo "[$SERVICE] deployed OK"
