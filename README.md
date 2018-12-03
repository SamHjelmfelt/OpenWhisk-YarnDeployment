# OpenWhisk-YarnDeployment

A refactored version of the openwhisk-devtools docker compose project made specifically for OpenWhisk on YARN. The "docker-whisk-controller.env" file can be used to configure the OpenWhisk services.

For a quickstart run the following:
```
# Download this repo
git clone https://github.com/SamHjelmfelt/OpenWhisk-YarnDeployment.git
cd OpenWhisk-YarnDeployment

# Edit YARN settings. By default, OpenWhisk action containers will be run on the local machine
vi docker-whisk-controller.env

# Download, build, and run OpenWhisk with YARN support
./YARNdeployment.sh quick-start https://github.com/SamHjelmfelt/incubator-openwhisk.git

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
  Stateful containers:  ow_minio, ow_couchdb, ow_zookeeper, ow_kafka, ow_redis
  Stateless containers: ow_controller, ow_invoker, ow_apigateway
./YARNdeployment.sh run-[stateful|stateless|all]    - Runs the specified containers
./YARNdeployment.sh stop-[stateful|stateless|all]   - Stops the specified containers
./YARNdeployment.sh start-[stateful|stateless|all]  - Starts the specified containers if they are stopped
./YARNdeployment.sh remove-[stateful|stateless|all] - Removes the specified containers

Shortcuts:
./YARNdeployment.sh quick-start <git url> - Executes download-source, build-docker, download-cli, run-stateful, run-stateless, init-cli
./YARNdeployment.sh launch - Executes run-stateful, run-stateless, init-cli
```
