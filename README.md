# Example of Continuous Delivery with Kubernetes and Monorepo

## Features

- Google Cloud Platform support - create new test cluster on each commit for test runs
- Docker for Mac support - deploy, run and test everything locally
- Integration tests made easy
- Pushback logic - easy to implement commit bots

### Suggested workflow

Once PR is made CI would create new Kuberentes cluster, deploy all apps, run all integration, optionally push back changes back to the branch, destroy test environment

Once PR is merged - deploy all new apps to production cluster. Google Container Builder is used for image building

### Setup

Starting point is [.circleci/config.yaml](). It's CircleCI config, but it's used only as an example and you can achieve exactly the same with Travis or self hosted solutions like Jenkins. Properties:

- `PROJECT` - Google Cloud Platform project to use
- `PROD_CLUSTER` - Production cluster name
- `NAMESPACE` - Google Container Registry namespace to use (gcr.io, eu.gcr.io, etc.)
- `COMPUTE_ZONE` - Google Cloud Platform zone to use for new cluster creation
- `ISOLATION` - Either `cluster` or `namespace`. First creates new cluster for each CI session, but it takes around 3m to start and kill the cluster. `namespace` isolation takes seconds to start and kill, but as it uses production cluster it may impact other apps there

git commands are needed if you would like to have pushback logic (described latter)

### Google Cloud Platform setup

Service account key with project access has to be presented as base64 string in `GC_SERVICE_KEY` environment variable. You may find how to do it here [https://circleci.com/docs/1.0/google-auth/](). Also service account has to have `Kubernetes Engine Admin` role. You can add it on IAM page - [https://console.cloud.google.com/iam-admin/iam/project](). Find your service account (most probably `[NUMBER]-compute@developer.gserviceaccount.com`) and add `Kubernetes Engine Admin` role there. This role is required for new Kubernetes service account creation which is needed for accessing Kubernetes API from inside the pod

### Production cluster setup

You can do it in Google Cloud Platform UI or simply via command like
```
gcloud container clusters create [NAME] \
       --cluster-version 1.8.5-gke.0 \
       --disk-size 100 \
       --machine-type g1-small \
       --num-nodes 3
```

### Local cluster

Install latest Docker for Mac with Kubernetes support then:
- `ENV=local PROJECT=test ACTION=build FILTER='' bash .circleci/ci.sh` - rebuild all Docker images and redeploy all services and apps into local cluster
- `ENV=local PROJECT=test ACTION=test FILTER='' bash .circleci/ci.sh` - rebuild all and then run all integrations in local cluster context

If you want to build/test only one app then set filter like `FILTER=front`. Those command are hard to remember, so [Makefile]() with those aliases is provided. Simply run `make build` or `make test` or use favorite build tool. 

You can access pods on your local cluster using [kubectl port-forward](https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/)

### Directory structure

- `apps` - folder for your pods, more info in [apps/README.md]()
- `jobs` - folder for your jobs, more info in [jobs/README.md]()
- `services` - folder for your statefulsets, more info in [services/README.md]()

### Integrations

For tests you may create `[integration-name].integration` files which are essentially Dockerfiles. Once all apps and services got deployed to test environment then all integrations will run, meaning you can run any kind of integration tests against your cluster there

### Pushback integrations

Traditionally CI were treated as read only workflow, but it opens new possibilities if you allow your CI to push changes as well.

Take an example of code format - your CI knows exactly how code should look like regarding spaces, semicolons, etc. and yet once it found that something is not right it just fails the build and that's it. But now many linters (tslint, eslint, etc.) has `--fix` flag which allows to fix those errors, and that exactly what pushback logic it meant for.

Example with prettier, just create `prettier.integration` with content like:
```
FROM node
WORKDIR /srv
RUN npm install prettier --global --silent
CMD prettier --write "*.js"
```
All integration has it's current folder mapped into `/srv` and any changes made there would be commited back to your branch. It works rather well for pull requests
