_       = require 'lodash'
async   = require 'async'
redis   = require 'fakeredis'
RedisNS = require '@octoblu/redis-ns'

uuid  = require 'uuid'
JobManagerAsync = require '../src/job-manager-async'

describe 'JobManagerAsync', ->
  beforeEach ->
    @redisId = uuid.v4()
    @client = _.bindAll new RedisNS 'ns', redis.createClient(@redisId)

    @sut = new JobManagerAsync
      client: _.bindAll new RedisNS 'ns', redis.createClient(@redisId)
      signallingClient: _.bindAll new RedisNS 'ns', redis.createClient(@redisId)
      timeoutSeconds: 1

  describe 'when instantiated without a timeout', ->
    it 'should blow up', ->
      expect(=> new JobManagerAsync client: @client).to.throw 'JobManagerAsync constructor is missing "timeoutSeconds"'

  describe 'when instantiated without a client', ->
    it 'should blow up', ->
      expect(=> new JobManagerAsync timeoutSeconds: 1).to.throw 'JobManagerAsync constructor is missing "client"'

  describe 'when instantiated without a signalling client', ->
    it 'should blow up', ->
      expect(=> new JobManagerAsync timeoutSeconds: 1, client: _.bindAll new RedisNS 'ns', redis.createClient(@redisId)).to.throw 'JobManagerAsync constructor is missing "signallingClient"'

  describe '->createRequest', ->
    context 'when called with a request', ->
      beforeEach (done) ->
        options =
          metadata:
            duel: "i'm just in it for the glove slapping"
            responseId: 'some-response-id'

        @sut.createRequest 'request', options, done

      it 'should place the job in a queue', (done) ->
        @timeout 3000
        @client.brpop 'request:queue', 1, (error, result) =>
          return done(error) if error?
          [channel, responseKey] = result
          expect(responseKey).to.deep.equal 'some-response-id'
          done()

      it 'should put the metadata in its place', (done) ->
        @client.hget 'some-response-id', 'request:metadata', (error, metadataStr) =>
          metadata = JSON.parse metadataStr
          expect(metadata).to.deep.equal
            duel: "i'm just in it for the glove slapping"
            responseId: 'some-response-id'
          done()

      it 'should put the data in its place', (done) ->
        @client.hget 'some-response-id', 'request:data', (error, dataStr) =>
          data = JSON.parse dataStr
          expect(data).to.be.null
          done()

      describe 'after the timeout has elapsed', (done) ->
        beforeEach (done) ->
          _.delay done, 1100

        it 'should not have any data', (done) ->
          @client.hlen 'some-response-id', (error, responseKeysLength) =>
            return done error if error?
            expect(responseKeysLength).to.equal 0
            done()

    context 'when called with data', ->
      beforeEach (done) ->
        options =
          metadata:
            responseId: 'some-response-id'
          data:
            'tunnel-collapse': 'just a miner problem'

        @sut.createRequest 'request', options, done

      it 'should stringify the data', (done) ->
        @client.hget 'some-response-id', 'request:data', (error, dataStr) =>
          data = JSON.parse dataStr
          expect(data).to.deep.equal 'tunnel-collapse': 'just a miner problem'
          done()

  describe '->createResponse', ->
    context 'when called with a response', ->
      beforeEach (done) ->
        options =
          metadata:
            responseId: 'some-response-id'
            duel: "i'm just in it for the glove slapping"

        @sut.createResponse 'response', options, done

      it 'should place the job in a queue', (done) ->
        @timeout 3000
        @client.brpop 'response:some-response-id', 1, (error, result) =>
          return done(error) if error?
          [channel, responseKey] = result
          expect(responseKey).to.deep.equal 'some-response-id'
          done()

      it 'should put the metadata in its place', (done) ->
        @client.hget 'some-response-id', 'response:metadata', (error, metadataStr) =>
          metadata = JSON.parse metadataStr
          expect(metadata).to.deep.equal
            duel: "i'm just in it for the glove slapping"
            responseId: 'some-response-id'
          done()

      it 'should put the data in its place', (done) ->
        @client.hget 'some-response-id', 'response:data', (error, metadataStr) =>
          metadata = JSON.parse metadataStr
          expect(metadata).to.be.null
          done()

      describe 'after the timeout has passed', ->
        beforeEach (done) ->
          _.delay done, 1100

        it 'should not have any data', (done) ->
          @client.hlen 'some-response-id', (error, responseKeysLength) =>
            return done error if error?
            expect(responseKeysLength).to.equal 0
            done()

    context 'when called with data', ->
      beforeEach (done) ->
        options =
          metadata:
            responseId: 'some-response-id'
          data:
            'tunnel-collapse': 'just a miner problem'

        @sut.createResponse 'request', options, done

      it 'should stringify the data', (done) ->
        @client.hget 'some-response-id', 'response:data', (error, dataStr) =>
          data = JSON.parse dataStr
          expect(data).to.deep.equal 'tunnel-collapse': 'just a miner problem'
          done()

  describe '->do', ->
    context 'when called with a request', ->
      beforeEach ->
        options =
          metadata:
            duel: "i'm just in it for the glove slapping"
            responseId: 'some-response-id'

        @onResponse = sinon.spy()
        @sut.do 'request', 'response', options, @onResponse

      describe 'when it receives a response', ->
        beforeEach (done) ->
          jobManager = new JobManagerAsync
            client: _.bindAll new RedisNS 'ns', redis.createClient(@redisId)
            signallingClient: _.bindAll new RedisNS 'ns', redis.createClient(@redisId)
            timeoutSeconds: 1

          jobManager.getRequest ['request'], (error, request) =>
            return done error if error?
            @responseId = request.metadata.responseId

            options =
              metadata:
                gross: true
                responseId: @responseId
              rawData: 'abcd123'

            jobManager.createResponse 'response', options, done

        it 'should yield the response', (done) ->
          onResponseCalled = => @onResponse.called
          wait = (callback) => _.delay callback, 10

          async.until onResponseCalled, wait, =>
            expect(@onResponse).to.have.been.calledWith null,
              metadata:
                gross: true
                responseId: @responseId
              rawData: 'abcd123'
            done()

  describe '->getRequest', ->
    context 'when called with a string instead of an array', ->
      beforeEach ->
        @callback = sinon.spy()
        @sut.getRequest 'hi', @callback

      it 'should blow up', ->
        [error] = @callback.firstCall.args
        expect(=> throw error).to.throw 'First argument must be an array'

    context 'when called with a request', ->
      beforeEach (done) ->
        options =
          metadata:
            gross: true
            responseId: 'some-response-id'
          rawData: 'abcd123'

        @sut.createRequest 'request', options, done

      beforeEach (done) ->
        @sut.getRequest ['request'], (error, @request) =>
          done error

      it 'should return a request', ->
        expect(@request).to.exist

        expect(@request.metadata).to.deep.equal
          gross: true
          responseId: 'some-response-id'

        expect(@request.rawData).to.deep.equal 'abcd123'

    context 'when called with a two queues', ->
      beforeEach (done) ->
        options =
          metadata:
            gross: true
            responseId: 'hairball'
          rawData: 'abcd123'

        @sut.createRequest 'request2', options, done

      beforeEach (done) ->
        @sut.getRequest ['request1', 'request2'], (error, @request) =>
          done error

      it 'should return a request', ->
        expect(@request).to.exist

        expect(@request.metadata).to.deep.equal
          gross: true
          responseId: 'hairball'

        expect(@request.rawData).to.deep.equal 'abcd123'

    context 'when called with a timed out request', ->
      beforeEach (done) ->
        options =
          metadata:
            gross: true
            responseId: 'hairball'
          rawData: 'abcd123'

        @sut.createRequest 'request2', options, (error) =>
          return done error if error?
          _.delay done, 1100

      beforeEach (done) ->
        @sut.getRequest ['request1', 'request2'], (error, @request) =>
          done error

      it 'should return a null request', ->
        expect(@request).not.to.exist

  describe '->getResponse', ->
    context 'when called with a request', ->
      beforeEach (done) ->
        options =
          metadata:
            gross: true
            responseId: 'hairball'
          rawData: 'abcd123'

        @sut.createResponse 'response', options, done

      beforeEach (done) ->
        @sut.getResponse 'response', 'hairball', (@error, @response) =>
          done()

      it 'should return a response', ->
        expect(@response).to.exist

        expect(@response.metadata).to.deep.equal
          gross: true
          responseId: 'hairball'

        expect(@response.rawData).to.deep.equal 'abcd123'

    context 'when called with a timed out response', ->
      beforeEach (done) ->
        options =
          metadata:
            gross: true
            responseId: 'hairball'
          rawData: 'abcd123'

        @sut.createResponse 'request2', options, (error) =>
          return done error if error?
          _.delay done, 1100

      beforeEach (done) ->
        @sut.getResponse 'request2', 'hairball', (@error, @request) =>
          done()

      it 'should return an error', ->
        expect(=> throw @error).to.throw 'Response timeout exceeded'

      it 'should return a null request', ->
        expect(@request).not.to.exist

    context 'when called with and no response', ->
      beforeEach (done) ->
        @sut.getResponse 'request2', 'hairball', (@error, @request) =>
          done()

      it 'should return an error', ->
        expect(=> throw @error).to.throw 'Response timeout exceeded'

      it 'should return a null request', ->
        expect(@request).not.to.exist
