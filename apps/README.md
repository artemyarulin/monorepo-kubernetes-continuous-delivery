# Apps

Apps are stateles pods which are deployed every CI session

## App configuration

Each folder is an app where name of the folder will be name of the app. Each app may have following files:

- `Dockerfile` - actual image for the app
- `app.yaml` - app definition. You may use `{NAME}` token to get job name and `{IMAGE}` for docker image location and `{PORT}` if you want to have defaul port used
- `config.yaml` - job config parameters. You may use `{NAME}` token to get job name

## App integrations

For testing the app you may create `[integration-name].integration` file which is essentially a Dockerfile. It will have full access to `config.yaml` variables and will be run on every CI run. Integration has it's current folder mapped on `/srv`, so no need to copy files. More over it's wriable and any changes in that folder will be commited back if you have pushback logic enabled
