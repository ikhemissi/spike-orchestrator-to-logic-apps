# CI/CD

The existing [CI workflow](../.github/workflows/ci.yml) runs `scripts/check.sh` on every pull request (and on pushes to `main`). A deployment pipeline can use the same check before deploying a reviewed revision.

## Provision and deploy

Authenticate the pipeline with a federated (OIDC) identity rather than a stored client secret. For the selected azd environment:

1. Run `azd provision --preview` and review the complete plan before applying it. Continue only when the planned changes are expected.
2. Run `azd provision` to apply the reviewed infrastructure plan.
3. Run `scripts/deploy-logicapp.sh` to zip-deploy the Logic App workflows.

The spike keeps the Logic App's public inbound access enabled for zip deployment (decision D7). A production pipeline that uses private inbound access runs on a deployment runner inside the network.

## Environments and tags

Use an azd environment for each deployment target and promote the same reviewed revision between environments by selecting the corresponding azd environment. Set tenant-required tags in that environment through the `RESOURCE_TAGS` azd value; do not put tenant-specific tags in repository files.
