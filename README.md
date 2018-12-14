# OpenWhisk-YarnDeployment

A refactored version of the openwhisk-devtools docker compose project made specifically for OpenWhisk on YARN. The "docker-whisk-controller.env" file can be used to configure the OpenWhisk services.

For a quickstart run the following:
```
# Download this repo
git clone https://github.com/SamHjelmfelt/OpenWhisk-YarnDeployment.git
cd OpenWhisk-YarnDeployment

# Edit YARN settings. Documentation can be found here: https://github.com/SamHjelmfelt/incubator-openwhisk/blob/master/docs/yarn.md
vi docker-whisk-controller.env

# Download, build, and run OpenWhisk with YARN support
./YARNdeployment.sh quick-start https://github.com/SamHjelmfelt/incubator-openwhisk.git yarnnetwork

# Test
./openwhisk-src/bin/wsk -i action create yahooWeather weather.js
./openwhisk-src/bin/wsk -i action invoke --blocking --result yahooWeather --param location "San Francisco, CA"
```

Usage:
```
Setup:
./YARNdeployment.sh download-source <git url> - Git clones the provided repo into ./openwhisk-src
./YARNdeployment.sh download-cli - Downloads the OpenWhisk cli into ./openwhisk-src/bin
./YARNdeployment.sh build-docker - Compiles the OpenWhisk source and builds the OpenWhisk images with a prefix of 'openwhisk'
./YARNdeployment.sh init-cli - Initializes the cli with the gateway endpoint and guest auth. All containers must be running

Container operations:
  Stateful containers:  ow_minio, ow_couchdb, ow_zookeeper, ow_kafka
  Stateless containers: ow_redis, ow_controller, ow_invoker, ow_apigateway
./YARNdeployment.sh run-stateful <docker network>                  - Runs the stateful containers locally
./YARNdeployment.sh run-stateless <docker network> [withJaaS]      - Runs the stateless containers locally
./YARNdeployment.sh run-stateless-yarn <RM URL>                    - Runs the stateless containers on YARN
./YARNdeployment.sh run-all <docker network> [withJaaS]            - Runs all containers locally
./YARNdeployment.sh stop-[stateful|stateless|all]                  - Stops the specified local containers
./YARNdeployment.sh start-[stateful|stateless|all]                 - Starts the specified local containers if they are stopped
./YARNdeployment.sh remove-[stateful|stateless|stateless-yarn|all] - Removes the specified containers

Shortcuts:
./YARNdeployment.sh quick-start <git url> <docker network> - Executes download-source, build-docker, download-cli, run-stateful, run-stateless, init-cli
./YARNdeployment.sh launch <docker network> - Executes run-stateful, run-stateless, init-cli
```
