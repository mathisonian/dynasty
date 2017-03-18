# Main Dynasty Class

aws = require('aws-sdk')
_ = require('lodash')
Promise = require('bluebird')
debug = require('debug')('dynasty')
https = require('https')
helpers = require('./lib/helpers')
awsTranslators = require('./lib/aws-translators')
dataTranslators = require('./lib/data-translators')

lib = require('./lib')
Table = lib.table

class Dynasty

  constructor: (credentials = {}, url) ->
    debug "dynasty constructed."
    credentials.region = credentials.region || 'us-east-1'

    # Lock API version
    credentials.apiVersion = '2012-08-10'

    if url and _.isString url
      debug "connecting to local dynamo at #{url}"
      credentials.endpoint = new aws.Endpoint url

    @dynamo = new aws.DynamoDB credentials
    Promise.promisifyAll @dynamo
    @name = 'Dynasty'
    @tables = {}

  loadAllTables: =>
    @list()
      .then (data) =>
        for tableName in data.TableNames
          @table(tableName)
        return @tables

  # Given a name, return a Table object
  table: (name) ->
    @tables[name] = @tables[name] || new Table this, name

  ###
  Table Operations
  ###

  # Alter an existing table. Wrapper around AWS updateTable
  alter: (name, params, callback) ->
    debug "alter() - #{name}, #{JSON.stringify(params, null, 4)}"
    # We'll accept either an object with a key of throughput or just
    # an object with the throughput info
    throughput = params.throughput || params

    awsParams =
      TableName: name
      ProvisionedThroughput:
        ReadCapacityUnits: throughput.read
        WriteCapacityUnits: throughput.write

    @dynamo
      .updateTableAsync(awsParams)
      .then (resp) ->
        return dataTranslators.tableFromDynamo resp.TableDescription
      .nodeify(callback)

  # Create a new table. Wrapper around AWS createTable
  create: (name, params, callback = null) ->
    debug "create() - #{name}, #{JSON.stringify(params, null, 4)}"
    throughput = params.throughput || {read: 10, write: 5}

    keySchema = [
      KeyType: 'HASH'
      AttributeName: params.key_schema.hash[0]
    ]

    attributeDefinitions = [
      AttributeName: params.key_schema.hash[0]
      AttributeType: dataTranslators.typeToAwsType[params.key_schema.hash[1]]
    ]

    if params.key_schema.range?
      keySchema.push
        KeyType: 'RANGE',
        AttributeName: params.key_schema.range[0]
      attributeDefinitions.push
        AttributeName: params.key_schema.range[0]
        AttributeType: dataTranslators.typeToAwsType[params.key_schema.range[1]]

    awsParams =
      AttributeDefinitions: attributeDefinitions
      TableName: name
      KeySchema: keySchema
      ProvisionedThroughput:
        ReadCapacityUnits: throughput.read
        WriteCapacityUnits: throughput.write

    # Add GlobalSecondaryIndexes to awsParams if provided
    if params.global_secondary_indexes?
      awsParams.GlobalSecondaryIndexes = []
      # Verify valid GSI
      for index in params.global_secondary_indexes
        key_schema = index.key_schema
        # Must provide hash type
        unless key_schema.hash?
          throw TypeError 'Missing hash index for GlobalSecondaryIndex'
        typesProvided = Object.keys(key_schema).length
        # Provide 1-2 types for GSI
        if typesProvided.length > 2 or typesProvided.length < 1
          throw RangeError 'Expected one or two types for GlobalSecondaryIndex'
        # Providing 2 types but the second isn't range type
        if typesProvided.length is 2 and not key_schema.range?
          throw TypeError 'Two types provided but the second isn\'t range'
      # Push each index
      for index in params.global_secondary_indexes
        keySchema = []
        for type, keys of index.key_schema
          keySchema.push({
            AttributeName: key[0]
            KeyType: type.toUpperCase()
          }) for key in keys
        awsParams.GlobalSecondaryIndexes.push {
          IndexName: index.index_name
          KeySchema: keySchema
          Projection:
            ProjectionType: index.projection_type.toUpperCase()
          # Use the provided or default throughput
          ProvisionedThroughput: unless index.provisioned_throughput? then awsParams.ProvisionedThroughput else {
            ReadCapacityUnits: index.provisioned_throughput.read
            WriteCapacityUnits: index.provisioned_throughput.write
          }
        }
        # Add key name to attributeDefinitions
        for type, keys of index.key_schema
          for key in keys
            awsParams.AttributeDefinitions.push {
              AttributeName: key[0]
              AttributeType: dataTranslators.typeToAwsType[key[1]]
            }

    debug "creating table with params #{JSON.stringify(awsParams, null, 4)}"

    @dynamo
      .createTableAsync(awsParams)
      .then (resp) ->
        # clean up the key schema
        return dataTranslators.tableFromDynamo resp.TableDescription
      .nodeify(callback)

  # describe
  describe: (name, callback) ->
    debug "describe() - #{name}"
    # if no name provided, throw an exception
    if not name
      throw new Error('Dynasty: Cannot invoke describe without providing a table name')
    @dynamo
      .describeTableAsync(TableName: name)
      .then (resp) ->
        # translate response
        output = dataTranslators.tableFromDynamo resp.Table
      .nodeify(callback)

  # Drop a table. Wrapper around AWS deleteTable
  drop: (name, callback = null) ->
    debug "drop() - #{name}"
    params =
      TableName: name

    @dynamo
      .deleteTableAsync(params)
      .then (resp) ->
        return dataTranslators.tableFromDynamo resp.TableDescription
      .nodeify(callback)

  # Drop all tables. CAUTION, DANGEROUS
  dropAll: (callback) ->
    debug "dropAll()"
    # While tables still left, drop 'em

    # Start with assumption that there is at least 1 table. This is ok because
    # worst case we fetch the list once and there are 0 that's still fine
    numTables = 1
    self = this
    helpers.promiseWhile () ->
      numTables > 0
    , () ->
      return self
        .list()
        .then (resp) ->
          numTables = resp.tables.length
          if numTables == 0
            return
          Promise.all resp.tables.map (table) ->
            return self.drop(table)
          .then () ->
            if resp.offset == ''
              debug "no more tables to delete"
              return
            else
              debug "getting more tables with offset #{resp.offset}"
              self.list(resp.offset)
    .nodeify(callback)

  # List tables. Wrapper around AWS listTables
  list: (params, callback) ->
    debug "list() - #{JSON.stringify(params, null, 4)}"
    awsParams = {}

    if params isnt null
      if _.isString params
        awsParams.ExclusiveStartTableName = params
      else if _.isFunction params
        callback = params
      else if _.isObject params
        if params.limit
          debug "list() - setting limit to #{params.limit}"
          awsParams.Limit = params.limit
        if params.offset
          debug "list() - setting offset to #{params.offset}"
          awsParams.ExclusiveStartTableName = params.start

    @dynamo.listTablesAsync(awsParams)
      .then (data) ->
        debug "list() - got #{data.TableNames.length} table names response from dynamo"
        resp =
          tables:
            data.TableNames
          offset:
            data.LastEvaluatedTableName || ""
        return resp
      .nodeify(callback)

module.exports = (credentials, url) -> new Dynasty(credentials, url)
