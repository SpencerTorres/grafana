"""
This module is a library of Drone steps and other pipeline components.
"""

load(
    "scripts/drone/steps/rgm.star",
    "rgm_build_backend_step",
)
load(
    "scripts/drone/utils/images.star",
    "images",
)
load(
    "scripts/drone/variables.star",
    "grabpl_version",
)
load(
    "scripts/drone/vault.star",
    "from_secret",
    "gcp_grafanauploads",
    "gcp_grafanauploads_base64",
    "gcp_upload_artifacts_key",
    "npm_token",
    "prerelease_bucket",
)

trigger_oss = {
    "repo": [
        "grafana/grafana",
    ],
}

def yarn_install_step():
    return {
        "name": "yarn-install",
        "image": images["node"],
        "commands": [
            # Python is needed to build `esfx`, which is needed by `msagl`
            "apk add --update g++ make python3 && ln -sf /usr/bin/python3 /usr/bin/python",
            "yarn install --immutable",
        ],
        "depends_on": [],
    }

def wire_install_step():
    return {
        "name": "wire-install",
        "image": images["go"],
        "commands": [
            "apk add --update make",
            "make gen-go",
        ],
        "depends_on": [
            "verify-gen-cue",
        ],
    }

def identify_runner_step():
    return {
        "name": "identify-runner",
        "image": images["alpine"],
        "commands": [
            "echo $DRONE_RUNNER_NAME",
        ],
    }

def enterprise_setup_step(source = "${DRONE_SOURCE_BRANCH}", canFail = True, isPromote = False):
    """Setup the enterprise source into the ./grafana-enterprise directory.

    Args:
      source: controls which revision of grafana-enterprise is checked out, if it exists. The name 'source' derives from the 'source branch' of a pull request.
      canFail: controls whether the step can fail. This is useful for pull requests where the enterprise source may not exist.
      isPromote: controls whether or not this step is being used in a promote pipeline. If it is, then the clone enterprise step will not check if the pull request is a fork.
    Returns:
        Drone step.
    """
    step = clone_enterprise_step_pr(source = source, target = "${DRONE_TARGET_BRANCH}", canFail = canFail, location = "../grafana-enterprise", isPromote = isPromote)
    step["commands"] += [
        "cd ../",
        "ln -s src grafana",
        "cd ./grafana-enterprise",
        "./build.sh",
    ]

    return step

def clone_enterprise_step_pr(source = "${DRONE_COMMIT}", target = "main", canFail = False, location = "grafana-enterprise", isPromote = False):
    """Clone the enterprise source into the ./grafana-enterprise directory.

    Args:
      source: controls which revision of grafana-enterprise is checked out, if it exists. The name 'source' derives from the 'source branch' of a pull request.
      target: controls which revision of grafana-enterprise is checked out, if it 'source' does not exist. The name 'target' derives from the 'target branch' of a pull request. If this does not exist, then 'main' will be checked out.
      canFail: controls whether or not this step is allowed to fail. If it fails and this is true, then the pipeline will continue. canFail is used in pull request pipelines where enterprise may be cloned but may not clone in forks.
      location: the path where grafana-enterprise is cloned.
      isPromote: controls whether or not this step is being used in a promote pipeline. If it is, then the step will not check if the pull request is a fork.
    Returns:
      Drone step.
    """

    if isPromote:
        check = []
    else:
        check = [
            'is_fork=$(curl "https://$GITHUB_TOKEN@api.github.com/repos/grafana/grafana/pulls/$DRONE_PULL_REQUEST" | jq .head.repo.fork)',
            'if [ "$is_fork" != false ]; then return 1; fi',  # Only clone if we're confident that 'fork' is 'false'. Fail if it's also empty.
        ]

    step = {
        "name": "clone-enterprise",
        "image": images["git"],
        "environment": {
            "GITHUB_TOKEN": from_secret("github_token"),
        },
        "commands": [
            "apk add --update curl jq bash",
        ] + check + [
            'git clone "https://$${GITHUB_TOKEN}@github.com/grafana/grafana-enterprise.git" ' + location,
            "cd {}".format(location),
            'if git checkout {0}; then echo "checked out {0}"; elif git checkout {1}; then echo "git checkout {1}"; else git checkout main; fi'.format(source, target),
        ],
    }

    if canFail:
        step["failure"] = "ignore"

    return step

def download_grabpl_step():
    return {
        "name": "grabpl",
        "image": images["curl"],
        "commands": [
            "mkdir -p bin",
            "curl -fL -o bin/grabpl https://grafana-downloads.storage.googleapis.com/grafana-build-pipeline/{}/grabpl".format(
                grabpl_version,
            ),
            "chmod +x bin/grabpl",
        ],
    }

def lint_drone_step():
    return {
        "name": "lint-drone",
        "image": images["curl"],
        "commands": [
            "./bin/build verify-drone",
        ],
        "depends_on": [
            "compile-build-cmd",
        ],
    }

def lint_starlark_step():
    return {
        "name": "lint-starlark",
        "image": images["go"],
        "commands": [
            "go install github.com/bazelbuild/buildtools/buildifier@latest",
            "buildifier --lint=warn -mode=check -r .",
        ],
        "depends_on": [
            "compile-build-cmd",
        ],
    }

def enterprise_downstream_step(ver_mode):
    """Triggers a downstream pipeline in the grafana-enterprise repository.

    Args:
      ver_mode: indirectly controls the revision used for downstream pipelines.
        It also used to allow the step to fail for pull requests without blocking merging.

    Returns:
      Drone step.
    """
    repo = "grafana/grafana-enterprise@"
    if ver_mode == "pr":
        repo += "${DRONE_SOURCE_BRANCH}"
    else:
        repo += "main"

    step = {
        "name": "trigger-enterprise-downstream",
        "image": images["drone_downstream"],
        "settings": {
            "server": "https://drone.grafana.net",
            "token": from_secret("drone_token"),
            "repositories": [
                repo,
            ],
            "params": [
                "SOURCE_BUILD_NUMBER=${DRONE_COMMIT}",
                "SOURCE_COMMIT=${DRONE_COMMIT}",
            ],
        },
    }

    if ver_mode == "pr":
        step.update({"failure": "ignore"})
        step["settings"]["params"].append("OSS_PULL_REQUEST=${DRONE_PULL_REQUEST}")

    return step

def lint_backend_step():
    return {
        "name": "lint-backend",
        "image": images["go"],
        "environment": {
            # We need CGO because of go-sqlite3
            "CGO_ENABLED": "1",
        },
        "depends_on": [
            "wire-install",
        ],
        "commands": [
            "apk add --update make build-base",
            # Don't use Make since it will re-download the linters
            "make lint-go",
        ],
    }

def validate_modfile_step():
    return {
        "name": "validate-modfile",
        "image": images["go"],
        "commands": [
            "go run scripts/modowners/modowners.go check go.mod",
        ],
    }

def validate_openapi_spec_step():
    return {
        "name": "validate-openapi-spec",
        "image": images["go"],
        "commands": [
            "apk add --update make",
            "make swagger-validate",
        ],
    }

def dockerize_step(name, hostname, port):
    return {
        "name": name,
        "image": images["dockerize"],
        "commands": [
            "dockerize -wait tcp://{}:{} -timeout 120s".format(hostname, port),
        ],
    }

def build_storybook_step(ver_mode):
    return {
        "name": "build-storybook",
        "image": images["node"],
        "depends_on": [
            # Best to ensure that this step doesn't mess with what's getting built and packaged
            "rgm-package",
            "build-frontend-packages",
        ],
        "environment": {
            "NODE_OPTIONS": "--max_old_space_size=4096",
        },
        "commands": [
            "yarn storybook:build",
            "./bin/build verify-storybook",
        ],
        "when": get_trigger_storybook(ver_mode),
    }

def store_storybook_step(ver_mode, trigger = None):
    """Publishes the Grafana UI components storybook.

    Args:
      ver_mode: controls whether a release or canary version is published.
      trigger: a Drone trigger for the step.
        Defaults to None.

    Returns:
      Drone step.
    """
    commands = []
    if ver_mode == "release":
        commands.extend(
            [
                "./bin/build store-storybook --deployment latest",
                "./bin/build store-storybook --deployment ${DRONE_TAG}",
            ],
        )

    else:
        # main pipelines should deploy storybook to grafana-storybook/canary public bucket
        commands = [
            "./bin/build store-storybook --deployment canary",
        ]

    step = {
        "name": "store-storybook",
        "image": images["publish"],
        "depends_on": [
                          "build-storybook",
                      ] +
                      end_to_end_tests_deps(),
        "environment": {
            "GCP_KEY": from_secret(gcp_grafanauploads),
            "PRERELEASE_BUCKET": from_secret(prerelease_bucket),
        },
        "commands": commands,
        "when": get_trigger_storybook(ver_mode),
    }
    if trigger and ver_mode in ("release-branch", "main"):
        # no dict merge operation available, https://github.com/harness/drone-cli/pull/220
        when_cond = {
            "repo": [
                "grafana/grafana",
            ],
            "paths": {
                "include": [
                    "packages/grafana-ui/**",
                ],
            },
        }
        step = dict(step, when = when_cond)
    return step

def e2e_tests_artifacts():
    return {
        "name": "e2e-tests-artifacts-upload",
        "image": images["cloudsdk"],
        "depends_on": [
            "end-to-end-tests-dashboards-suite",
            "end-to-end-tests-panels-suite",
            "end-to-end-tests-smoke-tests-suite",
            "end-to-end-tests-various-suite",
        ],
        "failure": "ignore",
        "when": {
            "status": [
                "success",
                "failure",
            ],
        },
        "environment": {
            "GCP_GRAFANA_UPLOAD_ARTIFACTS_KEY": from_secret(gcp_upload_artifacts_key),
            "E2E_TEST_ARTIFACTS_BUCKET": "releng-pipeline-artifacts-dev",
            "GITHUB_TOKEN": from_secret("github_token"),
        },
        "commands": [
            # if no videos found do nothing
            "if [ -z `find ./e2e -type f -name *spec.ts.mp4` ]; then echo 'missing videos'; false; fi",
            "apt-get update",
            "apt-get install -yq zip",
            "printenv GCP_GRAFANA_UPLOAD_ARTIFACTS_KEY > /tmp/gcpkey_upload_artifacts.json",
            "gcloud auth activate-service-account --key-file=/tmp/gcpkey_upload_artifacts.json",
            # we want to only include files in e2e folder that end with .spec.ts.mp4
            'find ./e2e -type f -name "*spec.ts.mp4" | zip e2e/videos.zip -@',
            "gsutil cp e2e/videos.zip gs://$${E2E_TEST_ARTIFACTS_BUCKET}/${DRONE_BUILD_NUMBER}/artifacts/videos/videos.zip",
            "export E2E_ARTIFACTS_VIDEO_ZIP=https://storage.googleapis.com/$${E2E_TEST_ARTIFACTS_BUCKET}/${DRONE_BUILD_NUMBER}/artifacts/videos/videos.zip",
            'echo "E2E Test artifacts uploaded to: $${E2E_ARTIFACTS_VIDEO_ZIP}"',
            'curl -X POST https://api.github.com/repos/${DRONE_REPO}/statuses/${DRONE_COMMIT_SHA} -H "Authorization: token $${GITHUB_TOKEN}" -d ' +
            '"{\\"state\\":\\"success\\",\\"target_url\\":\\"$${E2E_ARTIFACTS_VIDEO_ZIP}\\", \\"description\\": \\"Click on the details to download e2e recording videos\\", \\"context\\": \\"e2e_artifacts\\"}"',
        ],
    }

def upload_cdn_step(ver_mode, trigger = None):
    """Uploads CDN assets using the Grafana build tool.

    Args:
      ver_mode: only uses the step trigger when ver_mode == 'release-branch' or 'main'
      trigger: a Drone trigger for the step.
        Defaults to None.

    Returns:
      Drone step.
    """

    step = {
        "name": "upload-cdn-assets",
        "image": images["publish"],
        "depends_on": [
            "grafana-server",
        ],
        "environment": {
            "GCP_KEY": from_secret(gcp_grafanauploads),
            "PRERELEASE_BUCKET": from_secret(prerelease_bucket),
        },
        "commands": [
            "./bin/build upload-cdn --edition oss",
        ],
    }
    if trigger and ver_mode in ("release-branch", "main"):
        step = dict(step, when = trigger)
    return step

def build_backend_step(distros = "linux/amd64,linux/arm64"):
    """Build the backend code using the Grafana build tool.

    Args:
      distros: a list of distributes to be built. For a full list, see `go tool dist list`.

    Returns:
      Drone step.
    """

    return rgm_build_backend_step(distros)

def build_frontend_step():
    """Build the frontend code to ensure it's compilable

    Returns:
      Drone step.
    """
    return {
        "name": "build-frontend",
        "image": images["node"],
        "environment": {
            "NODE_OPTIONS": "--max_old_space_size=8192",
        },
        "depends_on": [
            "compile-build-cmd",
            "yarn-install",
        ],
        "commands": [
            "yarn build",
        ],
    }

def update_package_json_version():
    """Updates the packages/ to use a version that has the build ID in it: 10.0.0pre -> 10.0.0-5432pre

    Returns:
      Drone step that updates the 'version' key in package.json
    """

    return {
        "name": "update-package-json-version",
        "image": images["node"],
        "depends_on": [
            "yarn-install",
        ],
        "commands": [
            "apk add --update jq",
            "new_version=$(cat package.json | jq .version | sed s/pre/${DRONE_BUILD_NUMBER}/g)",
            "echo \"New version: $new_version\"",
            "yarn run lerna version $new_version --exact --no-git-tag-version --no-push --force-publish -y",
            "yarn install --mode=update-lockfile",
        ],
    }

def build_frontend_package_step(depends_on = []):
    """Build the frontend packages using the Grafana build tool.

    Args:
        depends_on: a list of step names (strings) that must complete before this step runs.

    Returns:
      Drone step.
    """

    cmds = [
        "apk add --update jq bash",  # bash is needed for the validate-npm-packages.sh script since it has a 'bash'
        # shebang.
        "yarn packages:build",
        "yarn packages:pack",
        "./scripts/validate-npm-packages.sh",
    ]

    return {
        "name": "build-frontend-packages",
        "image": images["node"],
        "environment": {
            "NODE_OPTIONS": "--max_old_space_size=8192",
        },
        "depends_on": [
            "yarn-install",
        ] + depends_on,
        "commands": cmds,
    }

def build_plugins_step(ver_mode):
    if ver_mode != "pr":
        env = {
            "GRAFANA_API_KEY": from_secret("grafana_api_key"),
        }
    else:
        env = None
    return {
        "name": "build-plugins",
        "image": images["node"],
        "environment": env,
        "depends_on": [
            "yarn-install",
        ],
        "commands": [
            "apk add --update findutils",  # Replaces the busybox 'find' with the GNU one.
            "yarn plugins:build",
        ],
    }

def test_backend_step():
    return {
        "name": "test-backend",
        "image": images["go"],
        "depends_on": [
            "wire-install",
        ],
        "commands": [
            # shared-mime-info and shared-mime-info-lang is used for exactly 1 test for the
            # mime.TypeByExtension function.
            "apk add --update build-base shared-mime-info shared-mime-info-lang",
            "go test -tags requires_buildifer -short -covermode=atomic -timeout=5m ./pkg/...",
        ],
    }

def test_backend_integration_step():
    return {
        "name": "test-backend-integration",
        "image": images["go"],
        "depends_on": [
            "wire-install",
        ],
        "commands": [
            "apk add --update build-base",
            "go test -count=1 -covermode=atomic -timeout=5m -run '^TestIntegration' $(find ./pkg -type f -name '*_test.go' -exec grep -l '^func TestIntegration' '{}' '+' | grep -o '\\(.*\\)/' | sort -u)",
        ],
    }

def betterer_frontend_step():
    """Run betterer on frontend code.

    Returns:
      Drone step.
    """

    return {
        "name": "betterer-frontend",
        "image": images["node"],
        "depends_on": [
            "yarn-install",
        ],
        "commands": [
            "apk add --update git bash",
            "yarn betterer ci",
        ],
    }

def test_frontend_step():
    """Runs tests on frontend code.

    Returns:
      Drone step.
    """

    return {
        "name": "test-frontend",
        "image": images["node"],
        "environment": {
            "TEST_MAX_WORKERS": "50%",
        },
        "depends_on": [
            "yarn-install",
        ],
        "commands": [
            "yarn run ci:test-frontend",
        ],
    }

def lint_frontend_step():
    return {
        "name": "lint-frontend",
        "image": images["node"],
        "environment": {
            "TEST_MAX_WORKERS": "50%",
        },
        "depends_on": [
            "yarn-install",
        ],
        "commands": [
            "yarn run prettier:check",
            "yarn run lint",
            "yarn run typecheck",
        ],
    }

def verify_i18n_step():
    extract_error_message = "\nExtraction failed. Make sure that you have no dynamic translation phrases, such as 't(\\`preferences.theme.\\$${themeID}\\`, themeName)' and that no translation key is used twice. Search the output for '[warning]' to find the offending file."
    uncommited_error_message = "\nTranslation extraction has not been committed. Please run 'yarn i18n:extract', commit the changes and push again."
    return {
        "name": "verify-i18n",
        "image": images["node"],
        "depends_on": [
            "yarn-install",
        ],
        "failure": "ignore",
        "commands": [
            "apk add --update git",
            "yarn run i18n:extract || (echo \"{}\" && false)".format(extract_error_message),
            # Verify that translation extraction has been committed
            '''
            file_diff=$(git diff --dirstat public/locales)
            if [ -n "$file_diff" ]; then
                echo $file_diff
                echo "{}"
                exit 1
            fi
            '''.format(uncommited_error_message),
        ],
    }

def test_a11y_frontend_step(ver_mode, port = 3001):
    """Runs automated accessiblity tests against the frontend.

    Args:
      ver_mode: controls whether the step is blocking or just reporting.
        If ver_mode == 'pr', the step causes the pipeline to fail.
      port: which port to grafana-server is expected to be listening on.
        Defaults to 3001.

    Returns:
      Drone step.
    """
    commands = [
        # Note - this runs in a container running node 14, which does not support the -y option to npx
        "npx wait-on@7.0.1 http://$HOST:$PORT",
    ]
    failure = "ignore"
    if ver_mode == "pr":
        commands.extend(
            [
                "pa11y-ci --config .pa11yci-pr.conf.js",
            ],
        )
        failure = "always"
    else:
        commands.extend(
            [
                "pa11y-ci --config .pa11yci.conf.js --json > pa11y-ci-results.json",
            ],
        )

    return {
        "name": "test-a11y-frontend",
        # TODO which image should be used?
        "image": images["docker_puppeteer"],
        "depends_on": [
            "grafana-server",
        ],
        "environment": {
            "GRAFANA_MISC_STATS_API_KEY": from_secret("grafana_misc_stats_api_key"),
            "HOST": "grafana-server",
            "PORT": port,
        },
        "failure": failure,
        "commands": commands,
    }

def frontend_metrics_step(trigger = None):
    """Reports frontend metrics to Grafana Cloud.

    Args:
      trigger: a Drone trigger for the step.
        Defaults to None.

    Returns:
      Drone step.
    """
    step = {
        "name": "publish-frontend-metrics",
        "image": images["node"],
        "depends_on": [
            "test-a11y-frontend",
        ],
        "environment": {
            "GRAFANA_MISC_STATS_API_KEY": from_secret("grafana_misc_stats_api_key"),
        },
        "failure": "ignore",
        "commands": [
            "apk add --update bash grep git",
            "./scripts/ci-frontend-metrics.sh ./grafana/public/build | ./bin/build publish-metrics $$GRAFANA_MISC_STATS_API_KEY",
        ],
    }
    if trigger:
        step = dict(step, when = trigger)
    return step

def codespell_step():
    return {
        "name": "codespell",
        "image": images["python"],
        "commands": [
            "pip3 install codespell",
            "codespell -I docs/.codespellignore docs/",
        ],
    }

def grafana_server_step():
    """Runs the grafana-server binary as a service.

    Returns:
      Drone step.
    """
    environment = {
        "GF_SERVER_HTTP_PORT": "3001",
        "GF_SERVER_ROUTER_LOGGING": "1",
        "GF_APP_MODE": "development",
    }

    return {
        "name": "grafana-server",
        "image": images["alpine"],
        "detach": True,
        "depends_on": [
            "rgm-package",
        ],
        "environment": environment,
        "commands": [
            "apk add --update tar bash",
            "mkdir grafana",
            "tar --strip-components=1 -xvf ./dist/*amd64.tar.gz -C grafana",
            "cp -r devenv scripts tools grafana && cd grafana && ./scripts/grafana-server/start-server",
        ],
    }

def e2e_tests_step(suite, port = 3001, tries = None):
    cmd = "./bin/build e2e-tests --port {} --suite {}".format(port, suite)
    if tries:
        cmd += " --tries {}".format(tries)
    return {
        "name": "end-to-end-tests-{}".format(suite),
        "image": images["cypress"],
        "depends_on": [
            "grafana-server",
        ],
        "environment": {
            "HOST": "grafana-server",
        },
        "commands": [
            cmd,
        ],
    }

def cloud_plugins_e2e_tests_step(suite, cloud, trigger = None):
    """Run cloud plugins end-to-end tests.

    Args:
      suite: affects the pipeline name.
        TODO: check if this actually affects step behavior.
      cloud: used to determine cloud provider specific tests.
      trigger: a Drone trigger for the step.
        Defaults to None.

    Returns:
      Drone step.
    """
    environment = {}
    when = {}
    if trigger:
        when = trigger
    if cloud == "azure":
        environment = {
            "CYPRESS_CI": "true",
            "HOST": "grafana-server",
            "GITHUB_TOKEN": from_secret("github_token"),
            "AZURE_SP_APP_ID": from_secret("azure_sp_app_id"),
            "AZURE_SP_PASSWORD": from_secret("azure_sp_app_pw"),
            "AZURE_TENANT": from_secret("azure_tenant"),
        }
        when = dict(
            when,
            paths = {
                "include": [
                    "pkg/tsdb/azuremonitor/**",
                    "public/app/plugins/datasource/azuremonitor/**",
                    "e2e/cloud-plugins-suite/azure-monitor.spec.ts",
                ],
            },
        )
    branch = "${DRONE_SOURCE_BRANCH}".replace("/", "-")
    step = {
        "name": "end-to-end-tests-{}-{}".format(suite, cloud),
        "image": "us-docker.pkg.dev/grafanalabs-dev/cloud-data-sources/e2e:3.0.0",
        "depends_on": [
            "grafana-server",
        ],
        "environment": environment,
        "commands": ["cd /", "./cpp-e2e/scripts/ci-run.sh {} {}".format(cloud, branch)],
    }
    step = dict(step, when = when)
    return step

def build_docs_website_step():
    return {
        "name": "build-docs-website",
        # Use latest revision here, since we want to catch if it breaks
        "image": images["docs"],
        "pull": "always",
        "commands": [
            "mkdir -p /hugo/content/docs/grafana/latest",
            "echo -e '---\\nredirectURL: /docs/grafana/latest/\\ntype: redirect\\nversioned: true\\n---\\n' > /hugo/content/docs/grafana/_index.md",
            "cp -r docs/sources/* /hugo/content/docs/grafana/latest/",
            "cd /hugo && make prod",
        ],
    }

def fetch_images_step():
    return {
        "name": "fetch-images",
        "image": images["cloudsdk"],
        "environment": {
            "GCP_KEY": from_secret(gcp_grafanauploads),
            "DOCKER_USER": from_secret("docker_username"),
            "DOCKER_PASSWORD": from_secret("docker_password"),
        },
        "commands": ["./bin/build artifacts docker fetch --edition oss"],
        "depends_on": ["compile-build-cmd"],
        "volumes": [{"name": "docker", "path": "/var/run/docker.sock"}],
    }

def publish_images_step(ver_mode, docker_repo, trigger = None):
    """Generates a step for publishing public Docker images with grabpl.

    Args:
      ver_mode: controls whether the image needs to be built or retrieved from a previous build.
        If ver_mode == 'release', the previously built image is fetched instead of being built again.
      docker_repo: the Docker image name.
        It is combined with the 'grafana/' library prefix.
      trigger: a Drone trigger for the pipeline.
        Defaults to None.

    Returns:
      Drone step.
    """
    name = docker_repo
    docker_repo = "grafana/{}".format(docker_repo)

    environment = {
        "GCP_KEY": from_secret(gcp_grafanauploads),
        "DOCKER_USER": from_secret("docker_username"),
        "DOCKER_PASSWORD": from_secret("docker_password"),
        "GITHUB_APP_ID": from_secret("delivery-bot-app-id"),
        "GITHUB_APP_INSTALLATION_ID": from_secret("delivery-bot-app-installation-id"),
        "GITHUB_APP_PRIVATE_KEY": from_secret("delivery-bot-app-private-key"),
    }

    cmd = "./bin/grabpl artifacts docker publish --dockerhub-repo {}".format(
        docker_repo,
    )

    deps = ["rgm-build-docker"]
    if ver_mode == "release":
        deps = ["fetch-images"]
        cmd += " --version-tag ${DRONE_TAG}"

    if ver_mode == "pr":
        environment = {
            "DOCKER_USER": from_secret("docker_username"),
            "DOCKER_PASSWORD": from_secret("docker_password"),
            "GITHUB_APP_ID": from_secret("delivery-bot-app-id"),
            "GITHUB_APP_INSTALLATION_ID": from_secret("delivery-bot-app-installation-id"),
            "GITHUB_APP_PRIVATE_KEY": from_secret("delivery-bot-app-private-key"),
        }

    step = {
        "name": "publish-images-{}".format(name),
        "image": images["cloudsdk"],
        "environment": environment,
        "commands": [cmd],
        "depends_on": deps,
        "volumes": [{"name": "docker", "path": "/var/run/docker.sock"}],
    }
    if trigger and ver_mode in ("release-branch", "main"):
        step = dict(step, when = trigger)
    if ver_mode == "pr":
        step = dict(step, failure = "ignore")

    return step

def integration_tests_steps(name, cmds, hostname = None, port = None, environment = None):
    """Integration test steps

    Args:
      name: the name of the step.
      cmds: the commands to run to perform the integration tests.
      hostname: the hostname where the remote server is available.
      port: the port where the remote server is available.
      environment: Any extra environment variables needed to run the integration tests.

    Returns:
      A list of drone steps. If a hostname / port were provided, then a step to wait for the remove server to be
      available is also returned.
    """
    dockerize_name = "wait-for-{}".format(name)

    depends = [
        "wire-install",
    ]

    step = {
        "name": "{}-integration-tests".format(name),
        "image": images["go"],
        "depends_on": depends,
        "commands": [
            "apk add --update build-base",
        ] + cmds,
    }

    if environment:
        step["environment"] = environment

    if hostname == None:
        return [step]

    depends = depends.append(dockerize_name)

    return [
        dockerize_step(dockerize_name, hostname, port),
        step,
    ]

def integration_benchmarks_step(name, environment = None):
    cmds = [
        "if [ -z ${GO_PACKAGES} ]; then echo 'missing GO_PACKAGES'; false; fi",
        "go test -v -run=^$ -benchmem -timeout=1h -count=8 -bench=. ${GO_PACKAGES}",
    ]

    return integration_tests_steps("{}-benchmark".format(name), cmds, environment = environment)

def postgres_integration_tests_steps():
    cmds = [
        "apk add --update postgresql-client",
        "psql -p 5432 -h postgres -U grafanatest -d grafanatest -f " +
        "devenv/docker/blocks/postgres_tests/setup.sql",
        "go clean -testcache",
        "go test -p=1 -count=1 -covermode=atomic -timeout=5m -run '^TestIntegration' $(find ./pkg -type f -name '*_test.go' -exec grep -l '^func TestIntegration' '{}' '+' | grep -o '\\(.*\\)/' | sort -u)",
    ]

    environment = {
        "PGPASSWORD": "grafanatest",
        "GRAFANA_TEST_DB": "postgres",
        "POSTGRES_HOST": "postgres",
    }

    return integration_tests_steps("postgres", cmds, "postgres", "5432", environment)

def mysql_integration_tests_steps(hostname, version):
    cmds = [
        "apk add --update mysql-client",
        "cat devenv/docker/blocks/mysql_tests/setup.sql | mysql -h {} -P 3306 -u root -prootpass".format(hostname),
        "go clean -testcache",
        "go test -p=1 -count=1 -covermode=atomic -timeout=5m -run '^TestIntegration' $(find ./pkg -type f -name '*_test.go' -exec grep -l '^func TestIntegration' '{}' '+' | grep -o '\\(.*\\)/' | sort -u)",
    ]

    environment = {
        "GRAFANA_TEST_DB": "mysql",
        "MYSQL_HOST": hostname,
    }

    return integration_tests_steps("mysql-{}".format(version), cmds, hostname, "3306", environment)

def redis_integration_tests_steps():
    cmds = [
        "go clean -testcache",
        "go test -run IntegrationRedis -covermode=atomic -timeout=2m ./pkg/...",
    ]

    environment = {
        "REDIS_URL": "redis://redis:6379/0",
    }

    return integration_tests_steps("redis", cmds, "redis", "6379", environment = environment)

def remote_alertmanager_integration_tests_steps():
    cmds = [
        "go clean -testcache",
        "go test -run TestIntegrationRemoteAlertmanager -covermode=atomic -timeout=2m ./pkg/services/ngalert/...",
    ]

    environment = {
        "AM_TENANT_ID": "test",
        "AM_URL": "http://mimir_backend:8080",
    }

    return integration_tests_steps("remote-alertmanager", cmds, "mimir_backend", "8080", environment = environment)

def memcached_integration_tests_steps():
    cmds = [
        "go clean -testcache",
        "go test -run IntegrationMemcached -covermode=atomic -timeout=2m ./pkg/...",
    ]

    environment = {
        "MEMCACHED_HOSTS": "memcached:11211",
    }

    return integration_tests_steps("memcached", cmds, "memcached", "11211", environment)

def release_canary_npm_packages_step(trigger = None):
    """Releases canary NPM packages.

    Args:
      trigger: a Drone trigger for the step.
        Defaults to None.

    Returns:
      Drone step.
    """
    step = {
        "name": "release-canary-npm-packages",
        "image": images["node"],
        "depends_on": end_to_end_tests_deps() + ["build-frontend-packages"],
        "environment": {
            "NPM_TOKEN": from_secret(npm_token),
        },
        "commands": [
            "apk add --update bash",
            "./scripts/publish-npm-packages.sh --dist-tag 'canary' --registry 'https://registry.npmjs.org'",
        ],
    }

    if trigger:
        step = dict(
            step,
            when = dict(
                trigger,
                paths = {
                    "include": [
                        "packages/**",
                    ],
                },
            ),
        )

    return step

def upload_packages_step(ver_mode, trigger = None):
    """Upload packages to object storage.

    Args:
      ver_mode: when ver_mode == 'main', inhibit upload of enterprise
        edition packages when executed.
      trigger: a Drone trigger for the step.
        Defaults to None.

    Returns:
      Drone step.
    """
    step = {
        "name": "upload-packages",
        "image": images["publish"],
        "depends_on": end_to_end_tests_deps(),
        "environment": {
            "GCP_KEY": from_secret(gcp_grafanauploads_base64),
            "PRERELEASE_BUCKET": from_secret("prerelease_bucket"),
        },
        "commands": [
            "./bin/build upload-packages --edition oss",
        ],
    }
    if trigger and ver_mode in ("release-branch", "main"):
        step = dict(step, when = trigger)
    return step

def publish_grafanacom_step(ver_mode):
    """Publishes Grafana packages to grafana.com.

    Args:
      ver_mode: if ver_mode == 'main', pass the DRONE_BUILD_NUMBER environment
        variable as the value for the --build-id option.
        TODO: is this actually used by the grafanacom subcommand? I think it might
        just use the environment variable directly.

    Returns:
      Drone step.
    """
    if ver_mode == "release":
        cmd = "./bin/build publish grafana-com --edition oss ${DRONE_TAG}"
    elif ver_mode == "main":
        build_no = "${DRONE_BUILD_NUMBER}"
        cmd = "./bin/build publish grafana-com --edition oss --build-id {}".format(
            build_no,
        )
    else:
        fail("Unexpected version mode {}".format(ver_mode))

    return {
        "name": "publish-grafanacom",
        "image": images["publish"],
        "depends_on": [
            "publish-linux-packages-deb",
            "publish-linux-packages-rpm",
        ],
        "environment": {
            "GRAFANA_COM_API_KEY": from_secret("grafana_api_key"),
            "GCP_KEY": from_secret(gcp_grafanauploads_base64),
        },
        "commands": [
            cmd,
        ],
    }

def publish_linux_packages_step(package_manager = "deb"):
    return {
        "name": "publish-linux-packages-{}".format(package_manager),
        # See https://github.com/grafana/deployment_tools/blob/master/docker/package-publish/README.md for docs on that image
        "image": images["package_publish"],
        "depends_on": ["compile-build-cmd"],
        "privileged": True,
        "settings": {
            "access_key_id": from_secret("packages_access_key_id"),
            "secret_access_key": from_secret("packages_secret_access_key"),
            "service_account_json": from_secret("packages_service_account"),
            "target_bucket": "grafana-packages",
            "deb_distribution": "auto",
            "gpg_passphrase": from_secret("packages_gpg_passphrase"),
            "gpg_public_key": from_secret("packages_gpg_public_key"),
            "gpg_private_key": from_secret("packages_gpg_private_key"),
            "package_path": "gs://grafana-prerelease/artifacts/downloads/*${{DRONE_TAG}}/oss/**.{}".format(
                package_manager,
            ),
        },
    }

def verify_gen_cue_step():
    return {
        "name": "verify-gen-cue",
        "image": images["go"],
        "depends_on": [],
        "commands": [
            "# It is required that code generated from Thema/CUE be committed and in sync with its inputs.",
            "# The following command will fail if running code generators produces any diff in output.",
            "apk add --update make",
            "CODEGEN_VERIFY=1 make gen-cue",
        ],
    }

def verify_gen_jsonnet_step():
    return {
        "name": "verify-gen-jsonnet",
        "image": images["go"],
        "depends_on": [],
        "commands": [
            "# It is required that generated jsonnet is committed and in sync with its inputs.",
            "# The following command will fail if running code generators produces any diff in output.",
            "apk add --update make",
            "CODEGEN_VERIFY=1 make gen-jsonnet",
        ],
    }

def end_to_end_tests_deps():
    return [
        "end-to-end-tests-dashboards-suite",
        "end-to-end-tests-panels-suite",
        "end-to-end-tests-smoke-tests-suite",
        "end-to-end-tests-various-suite",
    ]

def compile_build_cmd():
    dependencies = []

    return {
        "name": "compile-build-cmd",
        "image": images["go"],
        "commands": [
            "go build -o ./bin/build -ldflags '-extldflags -static' ./pkg/build/cmd",
        ],
        "depends_on": dependencies,
        "environment": {
            "CGO_ENABLED": 0,
        },
    }

def get_trigger_storybook(ver_mode):
    """Generate a Drone trigger for UI changes that affect the Grafana UI storybook.

    Args:
      ver_mode: affects whether the trigger is event tags or changed files.

    Returns:
      Drone trigger.
    """
    trigger_storybook = ""
    if ver_mode == "release":
        trigger_storybook = {"event": ["tag"]}
    else:
        trigger_storybook = {
            "paths": {
                "include": [
                    "packages/grafana-ui/**",
                ],
            },
        }
    return trigger_storybook

def slack_step(channel, template, secret):
    return {
        "name": "slack",
        "image": images["plugins_slack"],
        "settings": {
            "webhook": from_secret(secret),
            "channel": channel,
            "template": template,
        },
    }
