
###
FOR TESTS
###

IMAGES_N = 10


module.exports =

    run : () ->
        # DOM
        body = $('body')
        body.append """
            <button class="recreateBtn">re-create images</button>
            <button class="unloadBtn">unload images</button>
            <button class="reloadBtn">reload images</button>
            <button class="unReLoadBtn">unload and reload images</button>
            <button class="chainUnReLoadBtn">chain unload and reload images</button>
            <button class="chainDestroyReLoadBtn">chain destroy and reload images</button>
            <div></div>
        """

        recreateBtn              = body.find('.recreateBtn'          )
        unloadBtn                = body.find('.unloadBtn'            )
        reloadBtn                = body.find('.reloadBtn'            )
        unReLoadBtn              = body.find('.unReLoadBtn'          )
        chainUnReLoadBtn         = body.find('.chainUnReLoadBtn'     )
        chainDestroyReLoadBtnBtn = body.find('.chainDestroyReLoadBtn')
        imgContainer             = body.find('div'                   )

        # functions

        createImages = (e) ->
            imgContainer.html ''
            for i in [1..IMAGES_N]
                img = document.createElement('img')
                imgContainer.append img

        loadImages = (e) ->
            salt = Math.random() + '_'
            for img, i in imgContainer[0].children
                img.src = '/files/photo/cancelation-test/' + salt + (i+1)

        unLoadImages = (e) ->
            for img in imgContainer[0].children
                img.src = ''

        unReLoad = (e) ->
            unLoadImages()
            loadImages()

        destroyReLoad = (e) ->
            createImages()
            loadImages()

        # chain 5 times a cycle of unload and reload of images, with 100ms
        # between cycles.
        # Crash of server garanted :-)
        chainUnReLoads = (e) ->
            nPass = 1
            intervalID = window.setInterval () ->
                console.log ' chainUnReLoads', nPass
                unReLoad()
                nPass += 1
                if nPass > 5
                    console.log 'STOP'
                    window.clearInterval(intervalID)
            , 10

        chainDestroyReLoads = (e) ->
            nPass = 1
            intervalID = window.setInterval () ->
                console.log ' chainDestroyReLoads', nPass
                destroyReLoad()
                nPass += 1
                if nPass > 5
                    console.log 'STOP'
                    window.clearInterval(intervalID)
            , 10


        # events
        recreateBtn.on              'click', createImages
        unloadBtn.on                'click', unLoadImages
        reloadBtn.on                'click', loadImages
        unReLoadBtn.on              'click', unReLoad
        chainUnReLoadBtn.on         'click', chainUnReLoads
        chainDestroyReLoadBtnBtn.on 'click', chainDestroyReLoads

        # init
        createImages()
        # loadImages()


