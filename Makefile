bldNum = $(if $(BLD_NUM),$(BLD_NUM),999)
version = $(if $(VERSION),$(VERSION),1.0.0)
productVersion = $(version)-$(bldNum)
ARTIFACTS = build/artifacts/

# This allows the container tags to be explicitly set.
DOCKER_USER = couchbase
DOCKER_TAG = v1

# What exact revision is this?
GIT_REVISION := $(shell git rev-parse HEAD)

# Set this to, for example beta1, for a beta release.
# This will affect the "-v" version strings and docker images.
# This is analogous to revisions in DEB and RPM archives.
revision = $(if $(REVISION),$(REVISION),)

.PHONY: all build clean config-svc-lint container container-clean container-lint container-oss container-public container-scan dist \
        docs docs-generate-markdown docs-license-analysis docs-lint examples-clean example-kubernetes example-containers example-multi \
		lint test test-containers test-dist test-kubernetes test-native

# TODO: add 'test examples'
all: build clean container container-lint container-oss container-scan dist lint test-dist

# We need to copy docs in for packaging: https://github.com/moby/moby/issues/1676
# The other option is to tar things up and pass as the build context: tar -czh . | docker build -
build:
	rm -rf microlith/docs/
	cp -R docs/ microlith/docs/
	rm -rf microlith/config-svc/
	cp -R config-svc microlith/config-svc/
	echo "Version: $(version)" >> microlith/git-commit.txt
	echo "Build: $(productVersion)" > microlith/git-commit.txt
	echo "Revision: $(revision)" >> microlith/git-commit.txt
	echo "Git commit: $(GIT_REVISION)" >> microlith/git-commit.txt

image-artifacts: build
	mkdir -p $(ARTIFACTS)
	cp -rv microlith/* $(ARTIFACTS)

# This target (and only this target) is invoked by the production build job.
# This job will archive all files that end up in the dist/ directory.
dist: image-artifacts
	rm -rf dist
	mkdir -p dist
	tar -C $(ARTIFACTS) -czvf dist/couchbase-observability-stack-image_$(productVersion).tgz .
	rm -rf $(ARTIFACTS)

# NOTE: on Ansible linting failure due to YAML formatting, a pre-commit hook can be used to autoformat: https://pre-commit.com/
# Install pre-commit then run: pre-commit run --all-files
lint: config-svc-lint container-lint
	tools/asciidoc-lint.sh
	tools/shellcheck.sh
	ansible-lint
	tools/licence-lint.sh
	tools/dashboards-lint.sh

config-svc-build:
	DOCKER_BUILDKIT=1 docker build -t ${DOCKER_USER}/observability-stack-config-service:${DOCKER_TAG} config-svc/

config-svc-test-unit:
	DOCKER_BUILDKIT=1 docker build --target=unit-test config-svc/

config-svc-lint:
	docker run --rm -i -v  ${PWD}/config-svc:/app -w /app golangci/golangci-lint:v1.42.1 golangci-lint run -v

# NOTE: This target is only for local development.
container: build
	DOCKER_BUILDKIT=1 docker build --ssh default -f microlith/Dockerfile --build-arg CONFIG_SVC_IMAGE=${DOCKER_USER}/observability-stack-config-service:${DOCKER_TAG} -t ${DOCKER_USER}/observability-stack:${DOCKER_TAG} microlith/

container-oss: build
	tools/build-oss-container.sh

container-lint:
	tools/hadolint.sh

container-scan: container
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy \
		--severity "HIGH,CRITICAL" --ignore-unfixed --exit-code 1 --no-progress ${DOCKER_USER}/observability-stack:${DOCKER_TAG}
	-docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -e CI=true wagoodman/dive \
		${DOCKER_USER}/observability-stack:${DOCKER_TAG}

# This target pushes the containers to a public repository.
# A typical one liner to deploy to the cloud would be:
# 	make container-public -e DOCKER_USER=couchbase DOCKER_TAG=2.0.0
container-public: container
	docker push ${DOCKER_USER}/observability-stack:${DOCKER_TAG}

# Build and run the examples
example-kubernetes: container
	examples/kubernetes/run.sh

example-containers: container
	examples/containers/run.sh

example-multi: container
	examples/containers/multi/run.sh

# Deal with automated testing
test-kubernetes: TEST_SUITE ?= integration/kubernetes
test-kubernetes:
	# TODO (CMOS-97): no smoke suite for kubernetes yet
	testing/run-k8s.sh ${TEST_SUITE}

test-containers:
	testing/run-containers.sh ${TEST_SUITE}

test-native:
	testing/run-native.sh ${TEST_SUITE}

test-unit: config-svc-test-unit

test: clean container-oss test-native test-containers test-kubernetes

# Runs up the CMOS and takes screenshots
generate-screenshots: container-oss
	tools/generate-screenshots.sh

# Special target to verify the internal release pipeline will work as well
# Take the archive we would make and extract it to a local directory to then run the docker builds on
test-dist: dist
	rm -rf test-dist/
	mkdir -p test-dist/
	tar -xzvf dist/couchbase-observability-stack-image_$(productVersion).tgz -C test-dist/
	docker build -f test-dist/Dockerfile test-dist/ -t ${DOCKER_USER}/observability-stack-test-dist:${DOCKER_TAG}

test-dist-oss: dist
	rm -rf test-dist/
	mkdir -p test-dist/
	tar -xzvf dist/couchbase-observability-stack-image_$(productVersion).tgz -C test-dist/
	sed '/^# Couchbase proprietary start/,/^# Couchbase proprietary end/d' "test-dist/Dockerfile" > "test-dist/Dockerfile.oss"
	docker build -f test-dist/Dockerfile.oss test-dist/ -t ${DOCKER_USER}/observability-stack-test-dist:${DOCKER_TAG}

examples-clean: 
	-examples/containers/stop.sh
	rm -f examples/containers/logs/*.log
	-examples/kubernetes/stop.sh
	-examples/containers/multi/stop.sh

container-clean: examples-clean
	docker rmi -f ${DOCKER_USER}/observability-stack:${DOCKER_TAG} \
				  ${DOCKER_USER}/observability-stack-test-dist:${DOCKER_TAG} \
				  ${DOCKER_USER}/observability-stack-docs-generator:${DOCKER_TAG} \
				  ${DOCKER_USER}/observability-stack-config-service:${DOCKER_TAG}

clean: container-clean
	rm -rf $(ARTIFACTS) bin/ dist/ test-dist/ build/ .cache/ microlith/html/cmos/ microlith/docs/ microlith/config-svc/
	rm -f microlith/git-commit.txt

docs-license-analysis:
	tools/tern-report.sh
