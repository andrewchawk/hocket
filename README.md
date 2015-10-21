# Hocket #

Hocket - The Haskell [pocket](http://getpocket.com/) client

[![Build Status](https://travis-ci.org/markus1189/hocket.png?branch=master)](https://travis-ci.org/markus1189/hocket)

## About ##

Hocket is a minimalistic [pocket](http://getpocket.com/) client that
works on the commandline (using
[vty-ui](http://jtdaugherty.github.com/vty-ui/)) written in Haskell.

It's minimalistic in the sense that it matches my personal workflow
with pocket, currently supported features:

- view unread pocket items
- archive items (mark as read)
- rename items

## Installation ##

Hocket can be installed using `cabal`.

Arguments to the executable:

- `gui` - starts the gui
- `add <url>` - adds `<url>` to your pocket reading list and quits

## Authentication ##

Hocket requires a `hocket.cfg` file to authenticate you. Example:

```
[Credentials]
consumer_key = "12345-678912345678912345678912"
access_token = "abcdefgh-1234-abcd-1234-abcdef"

[Launch]
launch_cmd = firefox '%s'
```

Where `launch_cmd` is used to open a browser for the current pocket
item.

## How to get a consumer key and access token ##

NOTE: this is a little rough currently, because it has to be done only
once (and currently I am the only user).  Ideally this should be added
to `hocket` so that the user does not have to do the steps manually,
if you think so too, prs welcome!

1. Get a consumer key from http://getpocket.com/developer/apps/new
2.
  ```
  curl --data-urlencode consumer_key=YOUR_CONSUMER_KEY --data-urlencode redirect_uri=https://github.com/markus1189/hocket https://getpocket.com/v3/oauth/request`
  ```
  to get a request token
3. Go to
https://getpocket.com/auth/authorize?request_token=YOUR_REQUEST_TOKEN&redirect_uri=https://github.com/markus1189/hocket
4. Finally, get the access_token:
  ```
  curl --data-urlencode consumer_key='YOUR_CONSUMER_KEY' --data-urlencode code='YOUR_REQUEST_TOKEN' https://getpocket.com/v3/oauth/authorize
  ```

5. Fill in `consumer_key` and `access_token` into hour `hocket.cfg`

## Is it done? ##

No ;). As said above it is fairly minimalistic to fit my workflow,
nevertheless contributions are welcome!

## Screenshot ##

(text blur was added post screenshot)

![Screenshot](/pics/hocket.png?raw=true "Hocket screenshot")
