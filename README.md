# Claude Code in Docker Container

This is a solution for running claude code in a docker container. It assumes you are in MacOS.

## Prerequisites
- docker
- Claude Code Oauth Token
  - saved in Apple keychain under the name `claude_ouath_token`

## Setup
- copy `settings.json.example` to `settings.json`
  - `settings.json` is gitignored. Add your own settings here that will be used by Claude Code

## Run

- `cd` to the folder you want to run Claude Code from
- execute `run.sh` from that folder

### Example
```
- /Users/me/code
  - my-repo
  - claude-in-docker
```
```
$ cd ~/code/my-repo
$ ../claude-in-docker/run.sh
```
