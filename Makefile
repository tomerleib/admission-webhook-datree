#################
#    DEFAULTS   #
#################
CMD_DIR        := ./cmd
INIT_WEBHOOK_DIR    := $(CMD_DIR)/init-webhook
CERT_GENERATOR_DIR := $(CMD_DIR)/cert-generator
WEBHOOK_SERVER_DIR := $(CMD_DIR)/webhook-server

WEBHOOK_VERSION := 0.0.1
LD_FLAGS := "-X github.com/datreeio/admission-webhook-datree/pkg/config.WebhookVersion=$(WEBHOOK_VERSION)"
BUILD_ENVIRONMENT ?= staging
BUILD_DIR ?= $(WEBHOOK_SERVER_DIR)
HELM_CHART_DIR ?= ./charts/datree-admission-webhook


#################
#      RUN      #
#################

_runner: 
    go run -tags ${BUILD_ENVIRONMENT} -ldflags=$(LD_FLAGS) $(BUILD_DIR)

run-cert-generator-%:
     $(MAKE) _runner \
        -e BUILD_DIR=$(CERT_GENERATOR_DIR) \
        -e BUILD_ENVIRONMENT="$*"

run-init-webhook-%:
     $(MAKE) _runner \
        -e BUILD_DIR=$(INIT_WEBHOOK_DIR) \
        -e BUILD_ENVIRONMENT="$*"

run-webhook-server-%:
     $(MAKE) _runner \
        -e BUILD_DIR=$(WEBHOOK_SERVER_DIR) \
        -e BUILD_ENVIRONMENT="$*"


.PHONY: run-in-minikube
run-in-minikube:
	bash ./scripts/run-in-minikube.sh

#################
#      TEST     #
#################

test:
	DATREE_ENFORCE="true" go test ./...

.PHONY: test-in-minikube
test-in-minikube:
	bash ./scripts/test-in-minikube.sh
    
##################
#   BUILD  #
##################

_image_builder:
	docker build -t ${BUILD_TAG} -f $(BUILD_DIR)/Dockerfile . --build-arg BUILD_ENVIRONMENT=${BUILD_ENVIRONMENT}
    
image-build-cert-generator: 
	@echo "Building cert-generator image for environment ${BUILD_ENVIRONMENT}"
	$(MAKE) _image_builder \
        -e BUILD_DIR=$(CERT_GENERATOR_DIR) \
        -e BUILD_ENVIRONMENT=${BUILD_ENVIRONMENT}    \
        -e BUILD_TAG="cert-generator"

image-build-init-webhook: 
	@echo "Building init-webhook image for environment ${BUILD_ENVIRONMENT}"
	$(MAKE) _image_builder \
        -e BUILD_DIR=$(INIT_WEBHOOK_DIR) \
        -e BUILD_ENVIRONMENT="${BUILD_ENVIRONMENT}"  \
        -e BUILD_TAG="init-webhook"

image-build-webhook-server:
	@echo "Building webhook-server image for environment ${BUILD_ENVIRONMENT}"
	$(MAKE) _image_builder \
        -e BUILD_DIR=$(WEBHOOK_SERVER_DIR) \
        -e BUILD_ENVIRONMENT=${BUILD_ENVIRONMENT}    \
        -e BUILD_TAG="webhook-server"       

#########################
#    DEPLOY (LOCAL)     #
#########################

.PHONY: deploy-in-minikube
deploy-in-minikube:
	bash ./scripts/deploy-in-minikube.sh

# to connect minikube docker to local docker daemon (for local image building)
.PHONY: connect-minikube-docker
connect-minikube-docker:
	minikube addons enable registry
	docker run --rm -it --network=host alpine ash -c "apk add socat && socat TCP-LISTEN:5000,reuseaddr,fork TCP:$(minikube ip):5000"


LOCAL_REGISTRY := localhost:5000
IMAGE_TAG_LATEST := latest

# deploy-latest-image-init-webhook-local:
# 	@echo "Deploying init-webhook image with tag ${IMAGE_TAG_LATEST} to local registry"
# 	$(MAKE) image-build-init-webhook -e BUILD_ENVIRONMENT=main 
# 	docker tag init-webhook ${LOCAL_REGISTRY}/init-webhook:${IMAGE_TAG_LATEST}
# 	docker push ${LOCAL_REGISTRY}/init-webhook:${IMAGE_TAG_LATEST}

deploy-latest-image-cert-generator-local:
	@echo "Deploying cert-generator image with tag ${IMAGE_TAG_LATEST} to local registry"
	$(MAKE) image-build-cert-generator -e BUILD_ENVIRONMENT=main
	docker tag cert-generator ${LOCAL_REGISTRY}/cert-generator:${IMAGE_TAG_LATEST}
	docker push ${LOCAL_REGISTRY}/cert-generator:${IMAGE_TAG_LATEST}

deploy-latest-image-webhook-server-local:
	@echo "Deploying webhook-server image with tag ${IMAGE_TAG_LATEST} to local registry"
	$(MAKE) image-build-webhook-server -e BUILD_ENVIRONMENT=main
	docker tag webhook-server ${LOCAL_REGISTRY}/webhook-server:${IMAGE_TAG_LATEST}
	docker push ${LOCAL_REGISTRY}/webhook-server:${IMAGE_TAG_LATEST}

install-latest-datree-awsmp-local:
#	$(MAKE) deploy-latest-image-init-webhook-local
	$(MAKE) deploy-latest-image-cert-generator-local
	$(MAKE) deploy-latest-image-webhook-server-local

	helm install datree-webhook ./charts/datree-admission-webhook-awsmp --namespace datree --create-namespace \
                --set image.tag=latest --set image.repository=${LOCAL_REGISTRY}/webhook-server \
                --set initContainer.image.tag=latest --set initContainer.image.repository=${LOCAL_REGISTRY}/cert-generator \
                --debug


deploy-and-bump-all-local:
	$(MAKE) deploy-latest-image-init-webhook-local
	$(eval VERSION=$(shell yq '.image.tag' ${HELM_CHART_DIR}-awsmp/values.yaml | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g'))
	docker tag webhook-server ${LOCAL_REGISTRY}/webhook-server:${VERSION}
	docker push ${LOCAL_REGISTRY}/webhook-server:${VERSION}
	tag=${VERSION} yq e --inplace '.image."tag" |= strenv(tag)' ${HELM_CHART_DIR}-awsmp/values.yaml
	registry=${LOCAL_REGISTRY} yq e --inplace '.image."repository" |= strenv(registry)' ${HELM_CHART_DIR}-awsmp/values.yaml

	$(eval VERSION := $(shell yq '.initContainer.image.tag' ./charts/datree-admission-webhook-awsmp/values.yaml | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g'))
	docker tag cert-generator ${LOCAL_REGISTRY}/cert-generator:${VERSION}
	docker push ${LOCAL_REGISTRY}/cert-generator:${VERSION}
	tag=${VERSION} yq e --inplace '.initContainer.image."tag" |= strenv(tag)' ./charts/datree-admission-webhook-awsmp/values.yaml
	registry=${LOCAL_REGISTRY} yq e --inplace '.initContainer.image."repository" |= strenv(registry)' ./charts/datree-admission-webhook-awsmp/values.yaml

#	$(eval VERSION=$(shell yq '.image.initWebhook.tag' ./charts/datree-admission-webhook-awsmp/values.yaml | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g'))
#	docker tag init-webhook ${LOCAL_REGISTRY}/init-webhook:${VERSION}
#	docker push ${LOCAL_REGISTRY}/init-webhook:${VERSION}
#    tag=${VERSION} yq e --inplace '.image.initWebhook."tag" |= strenv(tag)' ./charts/datree-admission-webhook-awsmp/values.yaml
#    registry=${LOCAL_REGISTRY} yq e --inplace '.image.initWebhook."repository" |= strenv(registry)' ./charts/datree-admission-webhook-awsmp/values.yaml


#########################
#    DEPLOY (HELM)     #
#########################

helm-install-local-in-minikube:
    eval $(minikube docker-env) && \
    ./scripts/build-docker-image.sh && \
    helm install -n datree datree-webhook ./charts/datree-admission-webhook --set datree.token="${DATREE_TOKEN}"

helm-upgrade-local:
    helm upgrade -n datree datree-webhook ./charts/datree-admission-webhook --reuse-values --set datree.enforce="true"

helm-install-staging:
    helm install -n datree datree-webhook ./charts/datree-admission-webhook --set datree.token="${DATREE_TOKEN}" --set scan_job.image.repository="datree/scan-job-staging" \
    --set scan_job.image.tag="latest" --set image.repository="datree/webhook-staging" --set image.tag="latest"


############################
#  DEPLOY AWS MARKETPLACE  #
############################

ECR_REGISTRY := 709825985650.dkr.ecr.us-east-1.amazonaws.com

verify-ecr-registry:
	aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${ECR_REGISTRY}
deploy-image-webhook-server-ecr: 
	$(MAKE) verify-ecr-registry
	$(eval VERSION=$(shell yq '.image.tag' ${HELM_CHART_DIR}-awsmp/values.yaml | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g'))
	docker tag webhook-server ${ECR_REGISTRY}/datree/datree-admission-webhook:$(VERSION)
#	docker push ${ECR_REGISTRY}/datree-admission-webhook:${VERSION}

deploy-image-cert-generator-ecr:
	$(MAKE) verify-ecr-registry
	$(eval VERSION := $(shell yq '.initContainer.image.tag' ${HELM_CHART_DIR}-awsmp/values.yaml | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g'))
	docker tag cert-generator ${ECR_REGISTRY}/datree/datree-cert-generator:$(VERSION)
	docker push ${ECR_REGISTRY}/datree-cert-generator:${VERSION}


##################
#    RELEASE     #
##################

verify-helm-registry:
	aws ecr get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin ${ECR_REGISTRY}
	
release-chart-datree-awsmp:
# verify that the chart is valid
	helm lint ${HELM_CHART_DIR}-awsmp

# bump Helm Chart version 
	$(eval HELM_CHART_VERSION=$(shell yq '.version' ${HELM_CHART_DIR}-awsmp/Chart.yaml | awk -F. '{$$NF = $$NF + 1;} 1' | sed 's/ /./g'))
	version=${HELM_CHART_VERSION} yq e --inplace '."version" |= strenv(version)' ./charts/datree-admission-webhook-awsmp/Chart.yaml

# helm package the chart
	helm package ${HELM_CHART_DIR}-awsmp

# helm push chart to ECR
#	$(MAKE) verify-helm-registry
#	helm push datree-admission-webhook-awsmp-${HELM_CHART_VERSION}.tgz 709825985650.dkr.ecr.us-east-1.amazonaws.com


##################
#    CLEANUP     #
##################

.PHONY: helm-uninstall
helm-uninstall:
	helm uninstall -n datree datree-webhook

delete-eks-addon: 
	kubectl delete deployment datree-webhook-server -n datree
	$(MAKE) helm-uninstall