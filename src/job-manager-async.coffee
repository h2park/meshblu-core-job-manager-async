_     = require 'lodash'
async = require 'async'
debug = require('debug')('meshblu-core-job-manager:job-manager-async')
uuid  = require 'uuid'

class JobManagerAsync
  constructor: (options={}) ->
    {@client,@timeoutSeconds, @signallingClient} = options
    throw new Error 'JobManagerAsync constructor is missing "timeoutSeconds"' unless @timeoutSeconds?
    throw new Error 'JobManagerAsync constructor is missing "client"' unless @client?
    throw new Error 'JobManagerAsync constructor is missing "signallingClient"' unless @signallingClient?

  createRequest: (requestQueue, options, callback) =>
    {metadata,data,rawData} = options
    {responseId} = metadata
    data ?= null

    metadataStr = JSON.stringify metadata
    rawData ?= JSON.stringify data

    debug "@client.hset", "#{responseId}", 'request:metadata', metadataStr
    debug '@client.lpush', "#{requestQueue}:queue"
    async.series [
      async.apply @client.hset, "#{responseId}", 'request:metadata', metadataStr
      async.apply @client.hset, "#{responseId}", 'request:data', rawData
      async.apply @client.expire, "#{responseId}", @timeoutSeconds
      async.apply @client.lpush, "#{requestQueue}:queue", "#{responseId}"
      async.apply @client.publish, "#{requestQueue}:has-work", "true"
    ], callback

  createResponse: (responseQueue, options, callback) =>
    {metadata,data,rawData} = options
    {responseId} = metadata
    data ?= null

    metadataStr = JSON.stringify metadata
    rawData ?= JSON.stringify data

    debug "@client.hset", "#{responseId}", 'response:metadata', metadataStr
    debug "@client.expire", "#{responseId}", @timeoutSeconds
    debug "@client.lpush", "#{responseQueue}:#{responseId}", "#{responseId}"
    async.series [
      async.apply @client.hset, "#{responseId}", 'response:metadata', metadataStr
      async.apply @client.hset, "#{responseId}", 'response:data', rawData
      async.apply @client.expire, "#{responseId}", @timeoutSeconds
      async.apply @client.lpush, "#{responseQueue}:#{responseId}", "#{responseId}"
      async.apply @client.publish, "#{responseId}:work-complete", "true"
    ], callback

  do: (requestQueue, responseQueue, options, callback) =>
    options = _.clone options
    options.metadata.responseId ?= uuid.v4()
    {responseId} = options.metadata

    @createRequest requestQueue, options, =>
      @getResponse responseQueue, responseId, callback


  getRequest: (requestQueues, callback) =>
    debug "getRequest", {requestQueues}
    return callback new Error 'First argument must be an array' unless _.isArray requestQueues
    _.each requestQueues, (queue) =>
      @_getRequest queue, callback

  _getRequest: (requestQueue, callback) =>
    queue = "#{requestQueue}:queue"
    @client.rpop queue, (error, key) =>
      return callback error if error?
      return @waitForRequest(requestQueue, callback) unless key?
      debug "got request key", key

      async.parallel
        metadata: async.apply @client.hget, key, 'request:metadata'
        data: async.apply @client.hget, key, 'request:data'
      , (error, result) =>
        debug "_getRequest data", result
        return callback error if error?
        return callback null, null unless result?.metadata?
        callback null,
          metadata: JSON.parse result?.metadata
          rawData: result.data

  waitForRequest: (requestQueue, callback) =>
    requestChannel = "#{requestQueue}:has-work"
    debug "waitingForRequest", requestChannel

    @signallingClient.on 'message', (channel, message) =>
      debug "Request: work available", {requestQueue, message, requestChannel}
      @_getRequest requestQueue, callback if channel == requestChannel
      @signallingClient.unsubscribe requestChannel

    @signallingClient.subscribe requestChannel


  getResponse: (responseQueue, responseId, callback) =>
    debug "getResponse", {responseQueue, responseId}
    @client.rpop "#{responseQueue}:#{responseId}", (error, result) =>
      return callback error if error?
      return @waitForResponse(responseQueue, responseId, callback) unless result?

      async.parallel
        metadata: async.apply @client.hget, result, 'response:metadata'
        data: async.apply @client.hget, result, 'response:data'
      , (error, result) =>
        return callback error if error?
        return callback new Error('Response timeout exceeded'), null unless result.metadata?
        callback null,
          metadata: JSON.parse result.metadata
          rawData: result.data

  waitForResponse: (responseQueue, responseId, callback) =>
    debug "waitForResponse", {responseQueue, responseId}
    responseChannel = "#{responseId}:work-complete"
    responded = false

    @signallingClient.on 'message', (channel, message) =>
      debug "waitForResponse onMessage", {channel, message}
      return unless channel == responseChannel
      debug "response", {channel, message}
      @signallingClient.unsubscribe responseChannel
      @getResponse responseQueue, responseId, callback
      responded = true

    @signallingClient.subscribe responseChannel

    _.delay(
      =>
        return if responded
        @signallingClient.unsubscribe responseChannel
        callback new Error ('Response timeout exceeded')
      @timeoutSeconds * 1000
    )



module.exports = JobManagerAsync
