[![CircleCI](https://circleci.com/gh/sul-dlss/sdr-api.svg?style=svg)](https://circleci.com/gh/sul-dlss/sdr-api)
[![Maintainability](https://api.codeclimate.com/v1/badges/6e11d54474bfaf70480b/maintainability)](https://codeclimate.com/github/sul-dlss/sdr-api/maintainability)
[![Test Coverage](https://api.codeclimate.com/v1/badges/6e11d54474bfaf70480b/test_coverage)](https://codeclimate.com/github/sul-dlss/sdr-api/test_coverage)
[![OpenAPI Validator](http://validator.swagger.io/validator?url=https://raw.githubusercontent.com/sul-dlss/sdr-api/master/openapi.yml)](http://validator.swagger.io/validator/debug?url=https://raw.githubusercontent.com/sul-dlss/sdr-api/master/openapi.yml)
[![Docker image](https://images.microbadger.com/badges/image/suldlss/sdr-api.svg)](https://microbadger.com/images/suldlss/sdr-api "Get your own image badge on microbadger.com")

# Stanford Digital Repository API (SDR-API)

An HTTP API for the SDR.

There is a [OAS 3.0 spec](http://spec.openapis.org/oas/v3.0.2) that documents the API in [openapi.yml].  If you clone this repo, you can view this by opening [docs/index.html].

## Local Development

### Start dependencies

#### Database

```
docker-compose up -d db
```

### Build the api container

```
docker-compose build app
```

### Setup the local database

```
docker-compose run --rm app bundle exec rake db:create
docker-compose run --rm app bundle exec rake db:migrate
```

### Start the app

```
docker-compose up -d app
```

## Create a user

```
./bin/rails runner 'User.create!(email: "jcoyne@justincoyne.com", password:  "sekret!")'
```

## Authorization

Log in to get a token by calling:

```
curl -X POST -H 'Content-Type: application/json' \
  -d '{"email":"jcoyne@justincoyne.com","password":"sekret!"}' \
  http://{hostname}/v1/auth/login
```

In subsequent requests, submit the token in the `Authorization` header:


```
curl -H 'Accept: application/json' -H "Authorization: Bearer ${TOKEN}" https://{hostname}/api/myresource
```


## Sequence of operations

Given that we have a DRO with two Filesets each with a File (image1.png) and (image2.png)

1. Get base64 encoded md5 checksum of the files: `ruby -rdigest -e 'puts Digest::MD5.file("image1.png").base64digest'`
1. `curl -X POST -H 'Content-Type: application/json' -d '{"blob":{"byte_size":185464, "checksum":"Yw6eokcdYaqMAYioup0l7g==","content_type":"image/png","filename":"image.png"}}' http://localhost:3000/rails/active_storage/direct_uploads`
  This will return a payload with a `signed_id` and `direct_upload` object has the URL to send the file to.
1. PUT the content to the URL given in the previous step.
1. Repeat step 1-2 for the second file.
1. POST /filesets with the `signed_id` from step one.  Repeat for the second file. The API will use `ActiveStorage::Blob.find_signed(params[:signed_id])` to find the files.
1. POST /dro with the fileset ids from the previous step.
