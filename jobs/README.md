# Jobs

Job may be one of two types - one time run only and scheduled. While the second may be deployed (and updated) in the cluster easily and in a safe way with one time job it's not the case. First of all if you deploy the job then k8s will run it right away, which is not always intended. And if job was in a cluster before then k8s will return an error (you can use --force of cource, but sill). Because of it jobs are out of CI phase and requires manual deployment.

## Job configuration

Each folder is a job where name of the folder will be name of the job. Each job may have following files:

- `Dockerfile` - actual image for the job
- `job.yaml` - job definition. You may use `{NAME}` token to get job name and `{IMAGE}` for docker image location
- `config.yaml` - job config parameters. You may use `{NAME}` token to get job name

## Job integrations

For testing the job you may create `[integration-name].integration` file which is essentially a Dockerfile. It will have full access to `config.yaml` variables and will be run on every CI run. Integration has it's current folder mapped on `/srv`, so no need to copy files. More over it's wriable and any changes in that folder will be commited back if you have pushback logic enabled
