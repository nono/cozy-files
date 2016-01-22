fs = require 'fs'
async = require 'async'
moment = require 'moment'
crypto = require 'crypto'
multiparty = require 'multiparty'
mime = require 'mime'
log = require('printit')
    prefix: 'files'

cozydb = require 'cozydb'
File = require '../models/file'
Folder = require '../models/folder'
feed = require '../lib/feed'
sharing = require '../helpers/sharing'
pathHelpers = require '../helpers/path'
{normalizePath, getFileClass} = require '../helpers/file'

baseController = new cozydb.SimpleController
    model: File
    reqProp: 'file'
    reqParamID: 'fileid'


## FOR TESTS - TO BE DELETED ##
module.exports.destroyBroken = (req, res) ->
    res.send 400,
        error: true
        msg: "Deletion error for tests"


## Helpers ##


module.exports.fetch = (req, res, next, id) ->
    File.request 'all', key: id, (err, file) ->
        if err or not file or file.length is 0
            unless err?
                err = new Error 'File not found'
                err.status = 404
                err.template =
                    name: '404'
                    params:
                        localization: require '../lib/localization_manager'
                        isPublic: req.url.indexOf('public') isnt -1
            next err
        else
            req.file = file[0]
            next()


## Actions ##


module.exports.find = baseController.send
module.exports.all = baseController.listAll

# Perform download as an inline attachment.
sendBinary = baseController.sendBinary
    filename: 'file'

module.exports.getAttachment = (req, res, next) ->

    # Prevent server from stopping if the download is very slow.
    isDownloading = true
    do keepAlive = ->
        if isDownloading
            feed.publish 'usage.application', 'files'
            setTimeout keepAlive, 60 * 1000

    # Configure headers so clients know they should read and not download.
    encodedFileName = encodeURIComponent req.file.name
    res.setHeader 'Content-Disposition', """
        inline; filename*=UTF8''#{encodedFileName}
    """

    # Tell when the download is over in order to stop the keepAlive mechanism.
    res.on 'close', -> isDownloading = false
    res.on 'finish', -> isDownloading = false

    sendBinary req, res, next


# Perform download as a traditional attachment.
module.exports.downloadAttachment = (req, res, next) ->

    # Prevent server from stopping if the download is very slow.
    isDownloading = true
    do keepAlive = ->
        if isDownloading
            feed.publish 'usage.application', 'files'
            setTimeout keepAlive, 60 * 1000


    # Configure headers so clients know they should download, and that they
    # can make up the file name.
    encodedFileName = encodeURIComponent req.file.name
    res.setHeader 'Content-Disposition', """
        attachment; filename*=UTF8''#{encodedFileName}
    """

    # Tell when the download is over in order to stop the keepAlive mechanism.
    res.on 'close', -> isDownloading = false
    res.on 'finish', -> isDownloading = false

    sendBinary req, res, next


# Prior to file creation it ensures that all parameters are correct and that no
# file already exists with the same name. Then it builds the file document from
# given information and uploaded file metadata. Once done, it performs all
# database operation and index the file name. Finally, it tags the file if the
# parent folder is tagged.
folderParent = {}
timeout = null

# Helpers functions of upload process

# check if an error is storage related
isStorageError = (err) ->
    return err.toString().indexOf('enough storage') isnt -1

# After 1 minute of inactivity, update parents
resetTimeout = ->
    clearTimeout(timeout) if timeout?
    timeout = setTimeout updateParents, 60 * 1000


# Save in RAM lastModification date for parents
# Update folder parent once all files are uploaded
updateParents = ->
    errors = {}
    for name in Object.keys(folderParent)
        folder = folderParent[name]
        folder.save (err) ->
            errors[folder.name] = err if err?
    folderParent = {}


confirmCanUpload = (data, req, next) ->

    # owner can upload.
    return next null unless req.public
    element = new File data
    sharing.checkClearance element, req, 'w', (authorized, rule) ->
        if authorized
            if rule?
                req.guestEmail = rule.email
                req.guestId = rule.contactid
            next()
        else
            err = new Error 'You cannot access this resource'
            err.status = 404
            err.template =
                name: '404'
                params:
                    localization: require '../lib/localization_manager'
                    isPublic: true
            next err


module.exports.create = (req, res, next) ->
    clearTimeout(timeout) if timeout?

    fields = {}

    # Parse given form to extract image blobs.
    form = new multiparty.Form()

    form.on 'part', (part) ->
        # Get field, form is processed one way, be sure that fields are sent
        # before the file.
        # Parts are processed sequentially, so the data event should be
        # processed before reaching the file part.
        unless part.filename?
            fields[part.name] = ''
            part.on 'data', (buffer) ->
                fields[part.name] = buffer.toString()
            return

        # We assume that only one file is sent.
        # we do not write a subfunction because it seems to load the whole
        # stream in memory.
        name = fields.name
        path = fields.path
        lastModification = moment(new Date(fields.lastModification))
        lastModification = lastModification.toISOString()
        overwrite = fields.overwrite
        upload = true
        canceled = false
        uploadStream = null

        # we have no name for this file, give up
        if not name or name is ""
            err = new Error "Invalid arguments: no name given"
            err.status = 400
            return next err

        # while this upload is processing
        # we send usage.application to prevent auto-stop
        # and we defer parents lastModification update
        keepAlive = ->
            if upload
                feed.publish 'usage.application', 'files'
                setTimeout keepAlive, 60*1000
                resetTimeout()

        # if anything happens after the file is created
        # we need to destroy it
        rollback = (file, err) ->
            canceled = true
            file.destroy (delerr) ->
                # nothing more we can do with delerr
                log.error delerr if delerr
                if isStorageError err
                    res.send
                        error: true
                        code: 'ESTORAGE'
                        msg: "modal error size"
                    , 400
                else
                    next err

        attachBinary = (file) ->
            # request-json requires a path field to be set
            # before uploading
            part.path = file.name

            part.httpVersion = true # hack so form_data use length
            part.headers['content-length']?= part.byteCount

            checksum = crypto.createHash 'sha1'
            checksum.setEncoding 'hex'
            part.pause()
            part.pipe checksum
            metadata = name: "file"
            uploadStream = file.attachBinary part, metadata, (err) ->
                upload = false
                # rollback if there was an error
                return rollback file, err if err #and not canceled

                # TODO move everythin below in the model.
                checksum.end()
                checksum = checksum.read()

                # set the file checksum

                unless canceled

                    data =
                        checksum: checksum
                        uploading: false

                    file.updateAttributes data, (err) ->
                        # we ignore checksum storing errors
                        log.debug err if err

                        # index the file in cozy-indexer for fast search
                        file.index ["name"], (err) ->
                            # we ignore indexing errors
                            log.debug err if err

                            # send email or notification of file changed
                            who = req.guestEmail or 'owner'
                            sharing.notifyChanges who, file, (err) ->

                                # we ignore notification errors
                                log.debug err if err

                                # Retrieve binary metadat
                                File.find file.id, (err, file) ->
                                    log.debug err if err
                                    res.send file, 200

        now = moment().toISOString()

        # Check that the file doesn't exist yet.
        path = normalizePath path
        fullPath = "#{path}/#{name}"
        File.byFullPath key: fullPath, (err, sameFiles) ->
            return next err if err

            # there is already a file with the same name, give up
            if sameFiles.length > 0
                if overwrite
                    file = sameFiles[0]
                    attributes =
                        lastModification: lastModification
                        size: part.byteCount
                        mime: mime.lookup name
                        class: getFileClass part
                        uploading: true
                    return file.updateAttributes attributes, ->
                        # Ask for the data system to not run autostop
                        # while the upload is running.
                        keepAlive()

                        # Attach file in database.
                        attachBinary file
                else
                    upload = false
                    return res.send
                        error: true
                        code: 'EEXISTS'
                        msg: "This file already exists"
                    , 400

            # Generate file metadata.
            data =
                name: name
                path: normalizePath path
                creationDate: now
                lastModification: lastModification
                mime: mime.lookup name
                size: part.byteCount
                tags: []
                class: getFileClass part
                uploading: true

            # check if the request is allowed
            confirmCanUpload data, req, (err) ->
                return next err if err

                # find parent folder for updating its last modification
                # date and applying tags to uploaded file.
                Folder.byFullPath key: data.path, (err, parents) ->
                    return next err if err

                    # inherit parent folder tags and update its
                    # last modification date
                    if parents.length > 0
                        parent = parents[0]
                        data.tags = parent.tags
                        parent.lastModification = now
                        folderParent[parent.name] = parent

                    # Save file metadata
                    File.create data, (err, newFile) ->
                        return next err if err

                        # Ask for the data system to not run autostop
                        # while the upload is running.
                        keepAlive()

                        # If user stops the upload, the file is deleted.
                        err = new Error 'Request canceled by user'
                        res.on 'close', ->
                            log.info 'Upload request closed by user'
                            uploadStream.abort()

                        # Attach file in database.
                        attachBinary newFile

    form.on 'error', (err) ->
        log.error err

    form.parse req

module.exports.publicCreate = (req, res, next) ->
    req.public = true
    module.exports.create req, res, next

# There is two ways to modify a file:
# * change its tags: simple modification
# * change its name: it requires to check that no file has the same name, then
# it requires a new indexation.
module.exports.modify = (req, res, next) ->

    log.info "File modification of #{req.file.name}..."
    file = req.file
    body = req.body

    if body.tags and (Array.isArray body.tags) and
            file.tags?.toString() isnt body.tags?.toString()
        tags = body.tags
        tags = tags.filter (tag) -> typeof tag is 'string'
        file.updateAttributes tags: tags, (err) ->
            if err
                next new Error "Cannot change tags: #{err}"
            else
                log.info "Tags changed for #{file.name}: #{tags}"
                res.send success: 'Tags successfully changed', 200

    else if (not body.name or body.name is "") and not body.path?
        log.info "No arguments, no modification performed for #{req.file.name}"
        next new Error "Invalid arguments, name should be specified."

    # Case where path or name changed.
    else
        previousName = file.name
        newName = if body.name? then body.name else previousName
        previousPath = file.path
        body.path = normalizePath body.path if req.body.path?
        newPath = if body.path? then body.path else previousPath

        isPublic = body.public
        newFullPath = "#{newPath}/#{newName}"
        previousFullPath = "#{previousPath}/#{previousName}"

        File.byFullPath key: newFullPath, (err, sameFiles) ->
            return next err if err

            modificationSuccess =  (err) ->
                log.raw err if err
                log.info "Filechanged from #{previousFullPath} " + \
                         "to #{newFullPath}"
                res.send success: 'File successfully modified'

            if sameFiles.length > 0
                log.info "No modification: Name #{newName} already exists."
                res.send 400,
                    error: true
                    msg: "The name is already in use."
            else
                data =
                    name: newName
                    path: normalizePath newPath
                    public: isPublic

                data.clearance = body.clearance if body.clearance

                file.updateAttributes data, (err) ->
                    if err
                        next new Error 'Cannot modify file'
                    else
                        file.updateParentModifDate (err) ->
                            log.raw err if err
                            file.index ["name"], modificationSuccess


# Perform file removal and binaries removal.
module.exports.destroy = (req, res, next) ->
    file = req.file
    file.destroyWithBinary (err) ->
        if err
            log.error "Cannot destroy document #{file.id}"
            next err
        else
            file.updateParentModifDate (err) ->
                log.raw err if err
                res.send success: 'File successfully deleted'


# Check if the research should be performed on tag or not.
# For tag, it will use the Data System request. Else it will use the Cozy
# Indexer.
module.exports.search = (req, res, next) ->
    sendResults = (err, files) ->
        if err then next err
        else res.send files

    query = req.body.id
    query = query.trim()

    if query.indexOf('tag:') isnt -1
        parts = query.split()
        parts = parts.filter (tag) -> tag.indexOf 'tag:' isnt -1
        tag = parts[0].split('tag:')[1]
        File.request 'byTag', key: tag, sendResults
    else
        File.search "*#{query}*", sendResults


###*
 * Returns thumb for given file.
 * there is a bug : when the browser cancels many downloads, some are not
 * cancelled, what leads to saturate the stack of threads and blocks the
 * download of thumbs.
 * Cf comments bellow to reproduce easily
###
module.exports.photoThumb = (req, res, next) ->
    which = if req.file.binary.thumb then 'thumb' else 'file'
    stream = req.file.getBinary which, (err) ->
        if err
            console.log err
            next(err)
            stream.on 'data', () ->
            stream.on 'end', () ->
            stream.resume()
            return

    req.on 'close', () ->
        stream.abort()

    res.on 'close', () ->
        stream.abort()

    stream.pipe res



###*
 * test of cancelation of streams download
 * id of a file with a thumb :     c2b0bd61b4a6a8567001369ffb0a0eba
 * id of the corresponding thumb : c2b0bd61b4a6a8567001369ffb1d7ef3
###
module.exports.cancelationTest = (req, res, next) ->

    console.log 'bon début !', req.params.randomName
    fileID  = '18dbd1424d7c4858b3607f7b67993461'
    thumbID = '5d6e040ca1d6b922748af1724f004807'

    connectionClosed = false
    req.on 'close', -> connectionClosed = true
    res.on 'close', -> connectionClosed = true

    File.request 'all', key: fileID, (err, file) ->

        # If the browser closed its connection during the call to File.request,
        # stop here and do not create a stream. Else, the stream will become
        # zombie as no close or end events will be fired.
        if connectionClosed
            return

        else if err or not file or file.length is 0
            unless err?
                err = new Error 'File not found'
                err.status = 404
                err.template =
                    name: '404'
                    params:
                        localization: require '../lib/localization_manager'
                        isPublic: req.url.indexOf('public') isnt -1
            next err
        else
            req.file = file[0]
            stream = req.file.getBinary 'thumb', (err) ->
                if err
                    console.log err
                    next(err)
                    stream.on 'data', () ->
                    stream.on 'end', () ->
                    return

            req.on 'close', () ->
                console.log "reQ.on close", req.params.randomName
                # stream.destroy()
                # stream.abort()

            req.connection.on 'close', () ->
                console.log 'reQ.connection.on close', req.params.randomName
                # stream.destroy()
                # stream.abort()

            req.on 'end', () ->
                console.log 'reQ.on end', req.params.randomName
                res.end()
                # stream.destroy()
                # stream.abort()

            res.on 'close', () ->
                console.log "reS.on close", req.params.randomName
                stream.abort()
                # stream.destroy()
                # stream.abort()

            res.connection.on 'close', () ->
                console.log 'reS.connection.on close', req.params.randomName
                # stream.destroy()
                # stream.abort()

            res.on 'end', () ->
                console.log 'reS.on end', req.params.randomName
                # stream.destroy()
                # stream.abort()

            stream.on 'close', () ->
                console.log 'stream.on close', req.params.randomName
                # stream.destroy()
                # stream.abort()

            stream.on 'end', () ->
                console.log 'stream.on end', req.params.randomName
                # stream.destroy()
                # stream.abort()

            stream.pipe res
            # next()

    # next()
####
# traces : ce qui est étonnant ce sont les fermetures en masse des connections très tardivement.
# normal ?
# GET /clearance/contacts 200 7.364 ms - 297
# bon début ! 0.05164779396727681_1
# bon début ! 0.05164779396727681_2
# bon début ! 0.05164779396727681_3
# bon début ! 0.05164779396727681_4
# bon début ! 0.05164779396727681_5
# bon début ! 0.05164779396727681_6
# GET /files/photo/cancelation-test/0.05164779396727681_1 200 86.910 ms - -
# reQ.on end 0.05164779396727681_1
# bon début ! 0.05164779396727681_7
# GET /files/photo/cancelation-test/0.05164779396727681_2 200 95.880 ms - -
# reQ.on end 0.05164779396727681_2
# bon début ! 0.05164779396727681_10
# GET /files/photo/cancelation-test/0.05164779396727681_3 200 102.243 ms - -
# reQ.on end 0.05164779396727681_3
# bon début ! 0.05164779396727681_9
# GET /files/photo/cancelation-test/0.05164779396727681_4 200 110.023 ms - -
# reQ.on end 0.05164779396727681_4
# bon début ! 0.05164779396727681_8
# GET /files/photo/cancelation-test/0.05164779396727681_5 200 117.496 ms - -
# reQ.on end 0.05164779396727681_5
# bon début ! 0.04305103747174144_8
# GET /files/photo/cancelation-test/0.05164779396727681_6 200 128.784 ms - -
# reQ.on end 0.05164779396727681_6
# bon début ! 0.04305103747174144_2
# GET /files/photo/cancelation-test/0.05164779396727681_7 200 110.521 ms - -
# reQ.on end 0.05164779396727681_7
# GET /files/photo/cancelation-test/0.05164779396727681_10 200 115.870 ms - -
# reQ.on end 0.05164779396727681_10
# GET /files/photo/cancelation-test/0.05164779396727681_9 200 121.853 ms - -
# reQ.on end 0.05164779396727681_9
# GET /files/photo/cancelation-test/0.05164779396727681_8 200 126.277 ms - -
# reQ.on end 0.05164779396727681_8
# bon début ! 0.04305103747174144_1
# GET /files/photo/cancelation-test/0.04305103747174144_8 200 121.608 ms - -
# reQ.on end 0.04305103747174144_8
# GET /files/photo/cancelation-test/0.04305103747174144_2 200 112.260 ms - -
# reQ.on end 0.04305103747174144_2
# bon début ! 0.04305103747174144_7
# bon début ! 0.04305103747174144_9
# bon début ! 0.04305103747174144_10
# bon début ! 0.04305103747174144_4
# bon début ! 0.04305103747174144_6
# GET /files/photo/cancelation-test/0.04305103747174144_1 200 54.049 ms - -
# reQ.on end 0.04305103747174144_1
# bon début ! 0.04305103747174144_3
# GET /files/photo/cancelation-test/0.04305103747174144_7 200 58.012 ms - -
# reQ.on end 0.04305103747174144_7
# bon début ! 0.04305103747174144_5
# GET /files/photo/cancelation-test/0.04305103747174144_9 200 74.208 ms - -
# reQ.on end 0.04305103747174144_9
# bon début ! 0.34387736953794956_2
# GET /files/photo/cancelation-test/0.04305103747174144_10 200 68.829 ms - -
# reQ.on end 0.04305103747174144_10
# GET /files/photo/cancelation-test/0.04305103747174144_4 200 74.532 ms - -
# reQ.on end 0.04305103747174144_4
# bon début ! 0.34387736953794956_8
# GET /files/photo/cancelation-test/0.04305103747174144_6 200 106.495 ms - -
# reQ.on end 0.04305103747174144_6
# bon début ! 0.34387736953794956_10
# GET /files/photo/cancelation-test/0.04305103747174144_3 200 107.667 ms - -
# reQ.on end 0.04305103747174144_3
# GET /files/photo/cancelation-test/0.34387736953794956_8 200 55.902 ms - -
# reQ.on end 0.34387736953794956_8
# bon début ! 0.34387736953794956_4
# (node) warning: possible EventEmitter memory leak detected. 11 listeners added. Use emitter.setMaxListeners() to increase limit.
# Trace
#   at Socket.EventEmitter.addListener (events.js:160:15)
#   at Socket.Readable.on (_stream_readable.js:689:33)
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/server/controllers/files.coffee:528:28
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/model.js:200:18
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/cozymodel.js:254:18
#   at parseBody (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:75:10)
#   at IncomingMessage.<anonymous> (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:109:14)
#   at IncomingMessage.EventEmitter.emit (events.js:117:20)
#   at _stream_readable.js:920:16
#   at process._tickCallback (node.js:415:13)

# GET /files/photo/cancelation-test/0.04305103747174144_5 200 113.996 ms - -
# reQ.on end 0.04305103747174144_5
# bon début ! 0.34387736953794956_7
# GET /files/photo/cancelation-test/0.34387736953794956_2 200 97.625 ms - -
# reQ.on end 0.34387736953794956_2
# bon début ! 0.34387736953794956_5
# bon début ! 0.34387736953794956_9
# GET /files/photo/cancelation-test/0.34387736953794956_10 200 58.812 ms - -
# reQ.on end 0.34387736953794956_10
# bon début ! 0.34387736953794956_1
# (node) warning: possible EventEmitter memory leak detected. 11 listeners added. Use emitter.setMaxListeners() to increase limit.
# Trace
#   at Socket.EventEmitter.addListener (events.js:160:15)
#   at Socket.Readable.on (_stream_readable.js:689:33)
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/server/controllers/files.coffee:528:28
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/model.js:200:18
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/cozymodel.js:254:18
#   at parseBody (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:75:10)
#   at IncomingMessage.<anonymous> (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:109:14)
#   at IncomingMessage.EventEmitter.emit (events.js:117:20)
#   at _stream_readable.js:920:16
#   at process._tickCallback (node.js:415:13)

# bon début ! 0.34387736953794956_6
# GET /files/photo/cancelation-test/0.34387736953794956_4 200 61.286 ms - -
# reQ.on end 0.34387736953794956_4
# (node) warning: possible EventEmitter memory leak detected. 11 listeners added. Use emitter.setMaxListeners() to increase limit.
# Trace
#   at Socket.EventEmitter.addListener (events.js:160:15)
#   at Socket.Readable.on (_stream_readable.js:689:33)
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/server/controllers/files.coffee:528:28
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/model.js:200:18
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/cozymodel.js:254:18
#   at parseBody (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:75:10)
#   at IncomingMessage.<anonymous> (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:109:14)
#   at IncomingMessage.EventEmitter.emit (events.js:117:20)
#   at _stream_readable.js:920:16
#   at process._tickCallback (node.js:415:13)

# bon début ! 0.34387736953794956_3
# (node) warning: possible EventEmitter memory leak detected. 11 listeners added. Use emitter.setMaxListeners() to increase limit.
# Trace
#   at Socket.EventEmitter.addListener (events.js:160:15)
#   at Socket.Readable.on (_stream_readable.js:689:33)
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/server/controllers/files.coffee:528:28
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/model.js:200:18
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/cozymodel.js:254:18
#   at parseBody (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:75:10)
#   at IncomingMessage.<anonymous> (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:109:14)
#   at IncomingMessage.EventEmitter.emit (events.js:117:20)
#   at _stream_readable.js:920:16
#   at process._tickCallback (node.js:415:13)

# (node) warning: possible EventEmitter memory leak detected. 11 listeners added. Use emitter.setMaxListeners() to increase limit.
# Trace
#   at Socket.EventEmitter.addListener (events.js:160:15)
#   at Socket.Readable.on (_stream_readable.js:689:33)
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/server/controllers/files.coffee:528:28
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/model.js:200:18
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/cozymodel.js:254:18
#   at parseBody (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:75:10)
#   at IncomingMessage.<anonymous> (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:109:14)
#   at IncomingMessage.EventEmitter.emit (events.js:117:20)
#   at _stream_readable.js:920:16
#   at process._tickCallback (node.js:415:13)

# GET /files/photo/cancelation-test/0.34387736953794956_5 200 86.696 ms - -
# reQ.on end 0.34387736953794956_5
# bon début ! 0.14664509519934654_1
# GET /files/photo/cancelation-test/0.34387736953794956_7 200 97.256 ms - -
# reQ.on end 0.34387736953794956_7
# bon début ! 0.14664509519934654_2
# GET /files/photo/cancelation-test/0.34387736953794956_9 200 90.165 ms - -
# reQ.on end 0.34387736953794956_9
# bon début ! 0.14664509519934654_3
# (node) warning: possible EventEmitter memory leak detected. 11 listeners added. Use emitter.setMaxListeners() to increase limit.
# Trace
#   at Socket.EventEmitter.addListener (events.js:160:15)
#   at Socket.Readable.on (_stream_readable.js:689:33)
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/server/controllers/files.coffee:528:28
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/model.js:200:18
#   at /mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/lib/cozymodel.js:254:18
#   at parseBody (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:75:10)
#   at IncomingMessage.<anonymous> (/mnt/documents/Dev/code/cozy-vm-2/cozy-files/node_modules/cozydb/node_modules/request-json-light/main.js:109:14)
#   at IncomingMessage.EventEmitter.emit (events.js:117:20)
#   at _stream_readable.js:920:16
#   at process._tickCallback (node.js:415:13)

# GET /files/photo/cancelation-test/0.34387736953794956_1 200 134.859 ms - -
# reQ.on end 0.34387736953794956_1
# GET /files/photo/cancelation-test/0.34387736953794956_6 200 128.400 ms - -
# reQ.on end 0.34387736953794956_6
# GET /files/photo/cancelation-test/0.34387736953794956_3 200 119.538 ms - -
# reQ.on end 0.34387736953794956_3
# bon début ! 0.14664509519934654_4
# bon début ! 0.14664509519934654_5
# GET /files/photo/cancelation-test/0.14664509519934654_1 200 109.845 ms - -
# reQ.on end 0.14664509519934654_1
# bon début ! 0.14664509519934654_6
# GET /files/photo/cancelation-test/0.14664509519934654_2 200 122.699 ms - -
# reQ.on end 0.14664509519934654_2
# GET /files/photo/cancelation-test/0.14664509519934654_3 200 130.155 ms - -
# reQ.on end 0.14664509519934654_3
# bon début ! 0.14664509519934654_7
# GET /files/photo/cancelation-test/0.14664509519934654_4 200 75.185 ms - -
# reQ.on end 0.14664509519934654_4
# bon début ! 0.14664509519934654_8
# bon début ! 0.14664509519934654_9
# bon début ! 0.14664509519934654_10
# GET /files/photo/cancelation-test/0.14664509519934654_5 200 79.877 ms - -
# reQ.on end 0.14664509519934654_5
# bon début ! 0.8786530492361635_1
# GET /files/photo/cancelation-test/0.14664509519934654_6 200 87.371 ms - -
# reQ.on end 0.14664509519934654_6
# bon début ! 0.8786530492361635_2
# GET /files/photo/cancelation-test/0.14664509519934654_7 200 85.309 ms - -
# reQ.on end 0.14664509519934654_7
# GET /files/photo/cancelation-test/0.14664509519934654_8 200 81.360 ms - -
# reQ.on end 0.14664509519934654_8
# bon début ! 0.8786530492361635_3
# bon début ! 0.8786530492361635_4
# GET /files/photo/cancelation-test/0.14664509519934654_9 200 87.177 ms - -
# reQ.on end 0.14664509519934654_9
# bon début ! 0.8786530492361635_5
# GET /files/photo/cancelation-test/0.14664509519934654_10 200 114.373 ms - -
# reQ.on end 0.14664509519934654_10
# GET /files/photo/cancelation-test/0.8786530492361635_1 200 121.171 ms - -
# reQ.on end 0.8786530492361635_1
# GET /files/photo/cancelation-test/0.8786530492361635_3 200 81.213 ms - -
# reQ.on end 0.8786530492361635_3
# bon début ! 0.8786530492361635_6
# GET /files/photo/cancelation-test/0.8786530492361635_2 200 130.415 ms - -
# reQ.on end 0.8786530492361635_2
# bon début ! 0.8786530492361635_7
# bon début ! 0.8786530492361635_8
# GET /files/photo/cancelation-test/0.8786530492361635_4 200 103.987 ms - -
# reQ.on end 0.8786530492361635_4
# bon début ! 0.8786530492361635_9
# bon début ! 0.8786530492361635_10
# GET /files/photo/cancelation-test/0.8786530492361635_6 200 74.226 ms - -
# reQ.on end 0.8786530492361635_6
# GET /files/photo/cancelation-test/0.8786530492361635_5 200 134.722 ms - -
# reQ.on end 0.8786530492361635_5
# GET /files/photo/cancelation-test/0.8786530492361635_7 200 91.787 ms - -
# reQ.on end 0.8786530492361635_7
# GET /files/photo/cancelation-test/0.8786530492361635_8 200 89.622 ms - -
# reQ.on end 0.8786530492361635_8
# GET /files/photo/cancelation-test/0.8786530492361635_9 200 78.168 ms - -
# reQ.on end 0.8786530492361635_9
# GET /files/photo/cancelation-test/0.8786530492361635_10 200 106.466 ms - -
# reQ.on end 0.8786530492361635_10
# reQ.connection.on close 0.05164779396727681_1
# reS.connection.on close 0.05164779396727681_1
# reQ.connection.on close 0.05164779396727681_7
# reS.connection.on close 0.05164779396727681_7
# reQ.connection.on close 0.04305103747174144_1
# reS.connection.on close 0.04305103747174144_1
# reQ.connection.on close 0.04305103747174144_3
# reS.connection.on close 0.04305103747174144_3
# reQ.connection.on close 0.34387736953794956_9
# reS.connection.on close 0.34387736953794956_9
# reQ.connection.on close 0.14664509519934654_3
# reS.connection.on close 0.14664509519934654_3
# reQ.connection.on close 0.14664509519934654_7
# reS.connection.on close 0.14664509519934654_7
# reQ.connection.on close 0.8786530492361635_3
# reS.connection.on close 0.8786530492361635_3
# reQ.connection.on close 0.8786530492361635_6
# reS.connection.on close 0.8786530492361635_6
# reQ.connection.on close 0.05164779396727681_3
# reS.connection.on close 0.05164779396727681_3
# reQ.connection.on close 0.05164779396727681_9
# reS.connection.on close 0.05164779396727681_9
# reQ.connection.on close 0.04305103747174144_9
# reS.connection.on close 0.04305103747174144_9
# reQ.connection.on close 0.34387736953794956_2
# reS.connection.on close 0.34387736953794956_2
# reQ.connection.on close 0.34387736953794956_5
# reS.connection.on close 0.34387736953794956_5
# reQ.connection.on close 0.14664509519934654_1
# reS.connection.on close 0.14664509519934654_1
# reQ.connection.on close 0.14664509519934654_9
# reS.connection.on close 0.14664509519934654_9
# reQ.connection.on close 0.8786530492361635_5
# reS.connection.on close 0.8786530492361635_5
# reQ.connection.on close 0.05164779396727681_2
# reS.connection.on close 0.05164779396727681_2
# reQ.connection.on close 0.05164779396727681_10
# reS.connection.on close 0.05164779396727681_10
# reQ.connection.on close 0.04305103747174144_7
# reS.connection.on close 0.04305103747174144_7
# reQ.connection.on close 0.04305103747174144_5
# reS.connection.on close 0.04305103747174144_5
# reQ.connection.on close 0.34387736953794956_6
# reS.connection.on close 0.34387736953794956_6
# reQ.connection.on close 0.14664509519934654_6
# reS.connection.on close 0.14664509519934654_6
# reQ.connection.on close 0.8786530492361635_2
# reS.connection.on close 0.8786530492361635_2
# reQ.connection.on close 0.8786530492361635_8
# reS.connection.on close 0.8786530492361635_8
# reQ.connection.on close 0.05164779396727681_6
# reS.connection.on close 0.05164779396727681_6
# reQ.connection.on close 0.04305103747174144_2
# reS.connection.on close 0.04305103747174144_2
# reQ.connection.on close 0.04305103747174144_6
# reS.connection.on close 0.04305103747174144_6
# reQ.connection.on close 0.34387736953794956_7
# reS.connection.on close 0.34387736953794956_7
# reQ.connection.on close 0.14664509519934654_2
# reS.connection.on close 0.14664509519934654_2
# reQ.connection.on close 0.14664509519934654_10
# reS.connection.on close 0.14664509519934654_10
# reQ.connection.on close 0.8786530492361635_7
# reS.connection.on close 0.8786530492361635_7
# reQ.connection.on close 0.05164779396727681_5
# reS.connection.on close 0.05164779396727681_5
# reQ.connection.on close 0.04305103747174144_8
# reS.connection.on close 0.04305103747174144_8
# reQ.connection.on close 0.04305103747174144_4
# reS.connection.on close 0.04305103747174144_4
# reQ.connection.on close 0.34387736953794956_10
# reS.connection.on close 0.34387736953794956_10
# reQ.connection.on close 0.34387736953794956_1
# reS.connection.on close 0.34387736953794956_1
# reQ.connection.on close 0.14664509519934654_5
# reS.connection.on close 0.14664509519934654_5
# reQ.connection.on close 0.8786530492361635_1
# reS.connection.on close 0.8786530492361635_1
# reQ.connection.on close 0.8786530492361635_9
# reS.connection.on close 0.8786530492361635_9
# reQ.connection.on close 0.05164779396727681_4
# reS.connection.on close 0.05164779396727681_4
# reQ.connection.on close 0.05164779396727681_8
# reS.connection.on close 0.05164779396727681_8
# reQ.connection.on close 0.04305103747174144_10
# reS.connection.on close 0.04305103747174144_10
# reQ.connection.on close 0.34387736953794956_8
# reS.connection.on close 0.34387736953794956_8
# reQ.connection.on close 0.34387736953794956_4
# reS.connection.on close 0.34387736953794956_4
# reQ.connection.on close 0.34387736953794956_3
# reS.connection.on close 0.34387736953794956_3
# reQ.connection.on close 0.14664509519934654_4
# reS.connection.on close 0.14664509519934654_4
# reQ.connection.on close 0.14664509519934654_8
# reS.connection.on close 0.14664509519934654_8
# reQ.connection.on close 0.8786530492361635_4
# reS.connection.on close 0.8786530492361635_4
# reQ.connection.on close 0.8786530492361635_10
# reS.connection.on close 0.8786530492361635_10





###*
 * Returns "screens" (image reduced in ) for given file.
 * there is a bug : when the browser cancels many downloads, some are not
 * cancelled, what leads to saturate the stack of threads and blocks the
 * download of thumbs.
 * Cf comments bellow to reproduce easily
###
module.exports.photoScreen = (req, res, next) ->
    which = if req.file.binary.screen then 'screen' else 'file'
    stream = req.file.getBinary which, (err) ->
        if err
            console.log err
            next(err)
            stream.on 'data', () ->
            stream.on 'end', () ->
            stream.resume()
            return

    req.on 'close', () ->
        stream.abort()

    res.on 'close', () ->
        stream.abort()

    stream.pipe res
    ##
    # there is a bug : when the browser cancels many downloads, some are not
    # cancelled, what leads to saturate the stack of threads and blocks the
    # download of thumbs.
    # The code bellow makes it easy to reproduce the problem : just by delaying
    # the response, if you move the scrollbar in the browser, it will cancel
    # many photos...
    #
    # setTimeout(() ->
    #     stream = req.file.getBinary which, (err) ->
    #         if err
    #             console.log err
    #             next(err)
    #             stream.on 'data', () ->
    #             stream.on 'end', () ->
    #             stream.resume()
    #             return

    #     req.on 'close', () ->
    #         console.log "reQ.on close"
    #         stream.destroy()
    #         stream.abort()

    #     req.connection.on 'close', () ->
    #         console.log 'reQ.connection.on close'
    #         stream.destroy()
    #         stream.abort()

    #     req.on 'end', () ->
    #         console.log 'reQ.on end'
    #         stream.destroy()
    #         stream.abort()

    #     res.on 'close', () ->
    #         console.log "reS.on close"
    #         stream.abort()
    #         stream.destroy()
    #         stream.abort()

    #     res.connection.on 'close', () ->
    #         console.log 'reS.connection.on close'
    #         stream.destroy()
    #         stream.abort()

    #     res.on 'end', () ->
    #         console.log 'reS.on end'
    #         stream.destroy()
    #         stream.abort()

    #     stream.on 'close', () ->
    #         console.log 'stream.on close'
    #         stream.destroy()
    #         stream.abort()

    #     stream.pipe res
    # , 5000
    # )
    #
