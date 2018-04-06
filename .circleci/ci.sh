set -euo pipefail

log() {
    set -euo pipefail
    echo "[$(date)] $1"
}
export -f log

# Setup gcloud, service account auth, project, default zone
gc_set_project() {
    local key=$1
    local project=$2
    local zone=$3
    log "Setting GC project $project"
    echo $key | base64 --decode --ignore-garbage > ~/.gc_key
    gcloud auth activate-service-account --key-file ~/.gc_key
    gcloud config set project $project
    gcloud config set compute/zone $zone
}

# Authenticate so that kubectl has access to cluster
gc_cluster_auth() {
    local name=$1
    log "Cluster authentication $name"
    gcloud container clusters get-credentials $name
}

# Creates new kubernetes cluster
gc_create_cluster() {
    set -euo pipefail
    local name=$1
    log "Creating cluster $name of $CLUSTER_MACHINE_COUNT x $CLUSTER_MACHINE_TYPE"
    gcloud container clusters create $name \
           --cluster-version $CLUSTER_KUBERNETES_VER \
           --disk-size $CLUSTER_MACHINE_DISK \
           --machine-type $CLUSTER_MACHINE_TYPE \
           --num-nodes $CLUSTER_MACHINE_COUNT
    log "Cluster created: $?"
    kubectl describe nodes
}
export -f gc_create_cluster

# Creates (if not yet exists) new namespace and selects that as default one
namespace_switch() {
    set -euo pipefail
    local name=$1 res=0
    log "Namespace switching $name"
    kubectl get ns $name || res=$? && true
    if [[ $res -ne 0 ]]; then
        log "Namespace doesn't exists, creating"
        kubectl create ns $name
    fi
    kubectl config set-context $(kubectl config current-context) --namespace=$name
}
export -f namespace_switch

# Build all Dockerfiles (and *.integration) using local docker, builds all 1 by 1
build_local() {
    set -euo pipefail
    local version="$1"
    local filter="$2"
    log "Build local for $version filtered by $filter"
    for dockerfile in $(find . -name "Dockerfile" -o -name "*.integration"); do
        if [[ $filter && $dockerfile != *$filter* ]]; then continue; fi
        dir=$(dirname $dockerfile)
        app=$(echo $dockerfile | cut -d "/" -f 3 | sed "s/^[0-9]*-//" | sed "s/\./-/")
        tag_suffix=$(basename $dockerfile | sed "s/Dockerfile//; s/\.integration//; s/^/-/; s/^-$//")
        log "Building $dockerfile"
        (cd $dir && docker build --file $(basename $dockerfile) --tag $app$tag_suffix:$version .)
    done
}
export -f build_local

# Build all Dockerfiles (and *.integration) in parallel using Google Container Builder
build_gc() {
    set -euo pipefail
    local version=$1 namespace=$2 project=$3
    log "Build GC for $version in project $project"
    for dockerfile in $(find . -name "Dockerfile" -o -name "*.integration"); do
        dir=$(dirname $dockerfile)
        app=$(echo $dockerfile | cut -d "/" -f 3 | sed "s/^[0-9]*-//" | sed "s/\./-/")
        tag_suffix=$(basename $dockerfile | sed "s/Dockerfile//; s/\.integration//; s/^/-/; s/^-$//")
        image_name="$namespace/$project/$app$tag_suffix"
        template_file="container-build.yaml"
        cat .circleci/$template_file \
            | sed "s|{NAME}|$image_name:$version|" \
            | sed "s|{DOCKERFILE}|$(basename $dockerfile)|" > ./$dir/build.yaml.tmp
        (cd $dir && gcloud container builds submit --config build.yaml.tmp --async .)
    done

    log "Waiting for build to complete"
    while true; do
        if [[ $(gcloud container builds list --ongoing --filter "images ~ $namespace/$project/.*:$version" --format json) = "[]" ]]; then
            log "Done"
            break
        else
            echo -n "."
            sleep 5
        fi
    done

    failed=$(gcloud container builds list --filter "images ~ $namespace/$project/.*:$version AND status != SUCCESS" --format='value(id)')
    if [[ $failed ]]; then
        echo $failed | xargs -n 1 gcloud container builds log
        gcloud container builds list --filter "images ~ $namespace/$project/.*:$version"
        exit 1
    else
        gcloud container builds list --filter "images ~ $namespace/$project/.*:$version"
    fi
}
export -f build_gc

# Deploy services aka stetefulsets
deploy_services() {
    set -euo pipefail
    local pull_mode=$1
    local version=$2
    local namespace=$3
    local project=$4
    local filter=$5
    log "Deploying services with pull_mode $pull_mode"
    for path in services/*; do
        if [[ $filter && $path != *$filter* ]]; then continue; fi
        name=$(basename $path | sed "s/^[0-9]-//")
        image_pattern="s/{IMAGE}/$name:$version/"
        if [ "$pull_mode" == "gce" ]; then
            image_pattern="s/{IMAGE}/$namespace\/$project\/$name:$version/"
        fi
        if [ -f $path/service.yaml ]; then
            cat $path/service.yaml \
                | sed "$image_pattern" \
                | sed "s/{NAME}/$name/" \
                | kubectl apply --filename -
            kubectl rollout status statefulset/$name
        fi
    done
}
export -f deploy_services

# Apply service migrations if exists. It tracks list of applied migration using Kubernetes
# job list, so each migration would be run only once
services_migration() {
    local mode=$1
    local namespace=$2
    local project=$3
    local version=$4
    local filter=$5
    for path in services/*; do
        if [[ $filter && $path != *$filter* ]]; then continue; fi
        name=$(basename $path | sed "s/^[0-9]-//")
        image_pattern="s/{IMAGE}/$name:$version/"
        if [ $mode == "gc" ]; then
           image_pattern="s/{IMAGE}/$namespace\/$project\/$name:$version/"
        fi
        if [ -f $path/job.yaml ]; then
            if [[ $(kubectl get jobs "$name" --ignore-not-found) ]]; then
                   log "$name exists, skipping"
            else
              if [ -f $path/config.yaml ]; then
                  cat $path/config.yaml | sed "s/{NAME}/$name/" | kubectl apply --filename -
              fi
              cat $path/job.yaml \
                  | sed "$image_pattern" \
                  | sed "s/{NAME}/$name/" \
                  | kubectl apply --filename -
              bash .circleci/wait-for-task.sh --task-name "$name"
            fi
        fi
    done
}
export -f deploy_services

# Deploy apps using locally built images
deploy_apps_local() {
    set -euo pipefail
    local port=8080
    local filter=$1
    local version=$2
    log "Deploying locally apps filtered by $filter"
    for path in apps/*; do
        if [[ $filter && $path != *$filter* ]]; then continue; fi
        app=$(basename $path)
        if [ -f $path/config.yaml ]; then
            cat $path/config.yaml | sed "s/{NAME}/$app/" | kubectl apply --filename -
        fi
        if [ -f $path/app.yaml ]; then
            cat $path/app.yaml \
                | sed "s/{IMAGE}/$app:$version/" \
                | sed "s/{PORT}/$port/" \
                | sed "s/{NAME}/$app/" \
                | kubectl apply --filename -
            kubectl rollout status deployment/$app
        fi
    done
}
export -f deploy_apps_local

# Deploy apps using Google Container Build images
deploy_apps_gc() {
    set -euo pipefail
    local port=8080
    local namespace=$1
    local project=$2
    local version=$3
    log "Deploying GCP apps"
    for path in apps/*; do
        app=$(basename $path)
        if [ -f $path/config.yaml ]; then
            cat $path/config.yaml | sed "s/{NAME}/$app/" | kubectl apply --filename -
        fi
        if [ -f $path/app.yaml ]; then
            cat $path/app.yaml \
                | sed "s/{IMAGE}/$namespace\/$project\/$app:$version/" \
                | sed "s/{PORT}/$port/" \
                | sed "s/{NAME}/$app/" \
                | kubectl apply --filename -
            kubectl rollout status deployment/$app
        fi
    done
}
export -f deploy_apps_gc

# We don't deploy jobs as it starts automatically after deployment and it's not always intended
# But there are may be job config files that later on can be used for job tests, and we also do deploy
# CronJobs as those are safe to re-deploy
deploy_jobs() {
    set -euo pipefail
    local shouldDeploy=$1
    local version=$2
    local namespace=$3
    local project=$4
    local filter=$5
    for path in jobs/*; do
        if [[ $filter && $path != *$filter* ]]; then continue; fi

        name=$(basename $path)
        if [ -f $path/config.yaml ]; then
            cat $path/config.yaml | sed "s/{NAME}/$name/" | kubectl apply --filename -
        fi

        if [ ! -f $path/job.yaml ]; then continue; fi

        if [[ ! $(cat $path/job.yaml | grep "kind: CronJob") ]] || [ "$shouldDeploy" == "false" ]; then
            echo "Non deployable env or non CronJob, skipping the deployment, validation only"
            cat $path/job.yaml \
                | sed "s/{IMAGE}/$namespace\/$project\/$name:$version/" \
                | sed "s/{NAME}/$name/" \
                | kubectl apply --dry-run --filename -
            continue
        fi

        cat $path/job.yaml \
            | sed "s/{IMAGE}/$namespace\/$project\/$name:$version/" \
            | sed "s/{NAME}/$name/" \
            | kubectl apply --filename -
    done
}
export -f deploy_jobs

# Runs all *.integration in parallel as k8s jobs. We also attach [app|service|job] config if exits so that
# important environment variables can be accessed in test as well. Test runs in 3 stages:
# 1 Init container will prepeare files for integraion (think docker --volume $PWD:/srv)
# 2 Integration runs in k8s context with access to apps and services. /srv is writable and has files from integration folder
# 3 Sidecar container waits until main job has finished and copy /srv to sharer to be fetched later on for pushback logic
run_integrations() {
    image_source=$1
    tasks=()
    log "Running integrations for image_source $image_source"
    for integration in $(find . -name "*.integration"); do
        if [[ $FILTER && $integration != *$FILTER* ]]; then continue; fi
        key=ci-$VERSION-$(echo $integration | md5 | sed "s/  -//")
        app=$(echo $integration | cut -d "/" -f 3 | sed "s/^[0-9]*-//" | sed "s/\./-/")
        tag_suffix=$(basename $integration | sed "s/\.integration//; s/^/-/")
        image_name="$app$tag_suffix:$VERSION"
        if [[ $image_source == "gce" ]]; then image_name="$NAMESPACE\/$PROJECT\/"$image_name; fi
        name=$app$tag_suffix"-"${#tasks[@]}
        tasks+=($name)
        target_config=$(echo $integration | cut -d "/" -f 1-3)/config.yaml
        config=""
        if [ -f "$target_config" ]; then
            config=$'- configMapRef:\\\n              name: '$app
        fi
        service_acc=""
        if [[ $image_source == "gce" ]]; then
            service_acc="serviceAccountName: integration-runner"
        fi
        cat $(dirname $0)/integration-template.yaml \
            | sed "s/{NAME}/$name/" \
            | sed "s/{CONFIG}/$config/" \
            | sed "s|{IMAGE}|$image_name|" \
            | sed "s/{SERVICE_ACC}/$service_acc/" \
            | sed "s/{FOLDER}/$key/" \
            | kubectl apply --force --filename - # force is needed as we may need to replace existing job
    done
    if [ ${#tasks[@]} -ne 0 ]; then
        cmd_wait="bash $(dirname $0)/wait-for-task.sh --task-name"
        printf '%s\n' "${tasks[@]}" | parallel --joblog /tmp/jobs.log --halt 2 $cmd_wait
    fi
    cat /tmp/jobs.log
}

# SSH file exchange - used for pulling integration related files and pushing back after integraion changes
create_sharer() {
    set -euo pipefail
    local filter=$1
    local version=$2
    log "Creating sharer for version $version filtered by $filter"
    kubectl apply --filename .circleci/sharer.yaml
    kubectl rollout status deployment/sharer
    sharer=$(kubectl get pods --selector="app=sharer" --output=jsonpath={.items..metadata.name})
    for dockerfile in $(find . -name "*.integration"); do
        if [[ $filter && $dockerfile != *$filter* ]]; then continue; fi
        name=ci-$version-$(echo $dockerfile | md5 | sed "s/  -//")
        target_dir=$(dirname $dockerfile)
        echo "Prepearing data for $target_dir"
        kubectl cp $target_dir $sharer:/srv/$name
    done
}
export -f create_sharer

# Fetch data after integration and make a commit back when non local env is used
fetch_integration_data() {
    local version=$1 pushback=$2
    log "Fetching integration data with pushback $pushback"
    sharer=$(kubectl get pods --selector="app=sharer" --output=jsonpath={.items..metadata.name})
    msgs=()
    # Remove extra files before copy to make copy faster
    kubectl exec $sharer -- sh -c "find /srv -name node_modules -exec rm -rf {} +"
    for integration in $(find . -name "*.integration"); do
        if [[ $FILTER && $integration != *$FILTER* ]]; then continue; fi
        name=ci-$version-$(echo $integration | md5 | sed "s/  -//")
        app=$(echo $integration | cut -d "/" -f 3 | sed "s/^[0-9]*-//" | sed "s/\./-/")
        target_dir=$(dirname $integration)
        tag_suffix=$(basename $integration | sed "s/\.integration//; s/^/-/")
        friendly_name="$app$tag_suffix"
        (cd $target_dir && kubectl cp $sharer:/srv/$name .)
        if [[ $pushback == true && $(git status --porcelain $target_dir) ]]; then
            git stash save --include-untracked
            msgs+=("AUTOBOT: $friendly_name")
        fi
    done
    if [[ $pushback == true ]]; then
        for (( idx=${#msgs[@]}-1 ; idx>=0 ; idx-- )) ; do
            git stash pop
            git add --all
            git commit -m "${msgs[idx]}" || true
        done
        if [[ $(git log origin/$CIRCLE_BRANCH..$CIRCLE_BRANCH) ]]; then
            git push --set-upstream pushback $CIRCLE_BRANCH || true
        fi
    fi
}

# Checkc that no pods were restrted. Ensures that pods are stable
ensure_none_restarted() {
    # 1.9 has much better feature for filter https://github.com/kubernetes/kubernetes/issues/49387
    restarted=$(kubectl get pods --output="jsonpath={range .items[*]}{.metadata.name},{.status.containerStatuses..restartCount}{\"\n\"}{end}" | sed "/,[0 ]*0$/d" | cut -d ',' -f 1)
    if [[ $restarted ]]; then
        echo "Pods were restarted during testing: $restarted"
        echo "$restarted" | xargs -n 1 kubectl describe pod
        echo "$restarted" | xargs -n 1 kubectl logs --previous
        exit 1
    fi
}

# Runs integration locally
test_local() {
    log "Testing locally"
    run_integrations "local"
    fetch_integration_data "$VERSION" false
    kubectl get jobs --show-all
}

# Runs integration in GC
test_gc() {
    log "Testing on GCP"
    ensure_none_restarted
    run_integrations "gce"
    fetch_integration_data "$VERSION" true
    kubectl get jobs --show-all
    ensure_none_restarted
}

# Sets current build number
set_version() {
    log "Setting version"
    if [[ -n "${CIRCLE_BUILD_NUM:-}" ]]; then
        VERSION=$CIRCLE_BUILD_NUM
    else
        VERSION=$(date +%s)
    fi
    log "Version $VERSION"
}

# Initialize cluster wide secrets
init_secrets() {
    set -euo pipefail
    log "Init secrets"
    if [[ -f env/secrets.yaml ]]; then
        kubectl apply --filename env/secrets.yaml
    fi
    # Check if local override version exists and load that
    if [[ -f env/secrets.yaml.tmp ]]; then
        kubectl apply --filename env/secrets.yaml.tmp
    fi
}
export -f init_secrets

# Runs env -> build -> deploy -> test workflow
run() {
    local auth=$1 env=$2 build=$3 test=$4 services=$5 services_migration=$6 apps=$7 jobs=$8
    eval "$auth"
    if [[ $ACTION == "test" ]]; then
        (echo "$env && init_secrets && $services && create_sharer \"$FILTER\" \"$VERSION\""; echo "$build") | parallel --halt 2 --line-buffer
    else
        (echo "$env && init_secrets && $services"; echo "$build") | parallel --halt 2 --line-buffer
    fi
    eval "$services_migration"
    eval "$apps"
    eval "$jobs"
    if [[ $ACTION == "test" ]]; then eval "$test"; fi
}

auth_local() {
    log "Authenticating locally"
    kubectl config use-context docker-for-desktop
}

auth_gc() {
    log "Authenticating GCP"
    gc_set_project $GC_SERVICE_KEY $PROJECT $COMPUTE_ZONE
    gc_cluster_auth $PROD_CLUSTER
}

env_local() {
    set -euo pipefail
    local project=$1 version=$2
    log "Setting up local environment"
    namespace_switch $project
}
export -f env_local

# Integration tests has to have an access to k8s API from inside the pod
# New service account is created for that here
set_integration_permission() {
    set -euo pipefail
    local ns_name=$1
    log "Setting up integration permission for ns: $ns_name"
    cur_service_acc=$(gcloud config get-value account)
    raised_perm_name="ci-service-acc-admin"
    # Before creating new service account we need to raise cur acc permission
    if [[ $(kubectl get clusterrolebinding | grep $raised_perm_name) ]]; then
        log "Role already exists $raised_perm_name"
    else
        kubectl create clusterrolebinding $raised_perm_name \
                --clusterrole=cluster-admin \
                --user=$cur_service_acc
    fi
    name="integration-runner"
    cat .circleci/permission.yaml | \
        sed "s/{NAME}/$name/" | \
        sed "s/{NAMESPACE}/$ns_name/" | \
        kubectl apply --filename -
}
export -f set_integration_permission

env_gc() {
    set -euo pipefail
    local project=$1 version=$2 isolation=$3
    log "Setting up GCP environment with isolation: $isolation"
    name="ci-$project-$version"
    ns=$name
    if [[ $isolation == "cluster" ]]; then
        gc_create_cluster $name
        ns="default"
    else
        namespace_switch $name
    fi
    if [[ $ACTION == "test" ]]; then set_integration_permission $ns; fi
}
export -f env_gc

set_version

if [[ $ENV == "local" ]]; then
    auth="auth_local"
    env="env_local $PROJECT $VERSION $ACTION"
    build="build_local $VERSION \"$FILTER\""
    test="test_local"
    services="deploy_services local \"$VERSION\" \"\" \"$PROJECT\" \"$FILTER\""
    services_migrations="services_migration local \"\" \"$PROJECT\" \"$VERSION\" \"$FILTER\""
    apps="deploy_apps_local \"$FILTER\" \"$VERSION\""
    jobs="deploy_jobs false \"$VERSION\" \"\" \"$PROJECT\" \"$FILTER\""
    run "$auth" "$env" "$build" "$test" "$services" "$services_migrations" "$apps" "$jobs"
elif [[ $ENV == "test" ]]; then
    auth="auth_gc"
    env="env_gc $PROJECT $VERSION $ISOLATION"
    build="build_gc $VERSION $NAMESPACE $PROJECT"
    test="test_gc"
    services="deploy_services gce \"$VERSION\" \"$NAMESPACE\" \"$PROJECT\" \"$FILTER\""
    services_migrations="services_migration gc \"$NAMESPACE\" \"$PROJECT\" \"$VERSION\" \"$FILTER\""
    apps="deploy_apps_gc \"$NAMESPACE\" \"$PROJECT\" \"$VERSION\""
    jobs="deploy_jobs false \"$VERSION\" \"$NAMESPACE\" \"$PROJECT\" \"$FILTER\""
    run "$auth" "$env" "$build" "$test" "$services" "$services_migrations" "$apps" "$jobs"
elif [[ $ENV == "prod" && $ACTION == "build" ]]; then
    auth="auth_gc"
    env="echo Using production environment"
    build="build_gc $VERSION $NAMESPACE $PROJECT"
    test="echo No testing on prod"
    services="deploy_services gce \"$VERSION\" \"$NAMESPACE\" \"$PROJECT\" \"$FILTER\""
    services_migrations="services_migration gc \"$NAMESPACE\" \"$PROJECT\" \"$VERSION\" \"$FILTER\""
    apps="deploy_apps_gc \"$NAMESPACE\" \"$PROJECT\" \"$VERSION\""
    jobs="deploy_jobs true \"$VERSION\" \"$NAMESPACE\" \"$PROJECT\" \"$FILTER\""
    run "$auth" "$env" "$build" "$test" "$services" "$services_migrations" "$apps" "$jobs"
else
    log "Not supported env or project: $ENV, $PROJECT"
    exit 1
fi
