VERSION     = $(shell grep "^VER=" ../instance-duration-collect.sh | awk -F'=' '{print $$2}')
REPO		= repo.prophetservice.com:8084/tmp/instance-duration

all: build push

build:
	@cp -f ../instance-duration-collect.sh .
	docker build -t $(REPO):$(VERSION) .
	@rm -f instance-duration-collect.sh

push:
	docker push $(REPO):$(VERSION)
