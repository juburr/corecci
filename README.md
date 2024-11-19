<div align="center">
  <h1>CoreCCI</h1>
  <i>An unofficial CircleCI orb providing extended core functionality to your CI pipelines.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/corecci.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/corecci) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/corecci.svg)](https://circleci.com/developer/orbs/orb/juburr/corecci) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/corecci/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)



## Features
- `corecci/checkout_fips` - FIPS compliant checkout command using ECDSA keys. The built-in "Add deploy key" button adds a RSA or ED25519 key by default, which fails if you have a job running in a FIPS-enabled container such as ubi9.

- `corecci/checkout_shallow` - Shallow checkout command, allowing extremely fast checkouts when using massive repositories.

- `corecci/persist_to_s3` - Persist files to an S3 bucket, useful for either long-term deployment needs or as an alternative to the slow `persist_to_workspace` command that spends tons of time tar'ing and untar'ing files.