build: ; ENV=local PROJECT=test ACTION=build FILTER=$(FILTER) bash .circleci/ci.sh
test: ; ENV=local PROJECT=test ACTION=test FILTER=$(FILTER) bash .circleci/ci.sh
