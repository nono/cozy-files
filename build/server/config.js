// Generated by CoffeeScript 1.10.0
var GB, americano, config, errorHandler, getTemplateExt, path, publicStatic, staticMiddleware;

path = require('path');

americano = require('americano');

errorHandler = require('./middlewares/errors');

getTemplateExt = require('./helpers/get_template_ext');

staticMiddleware = americano["static"](path.resolve(__dirname, '../client/public'), {
  maxAge: 86400000
});

publicStatic = function(req, res, next) {
  var assetsMatched, detectAssets;
  detectAssets = /\/(stylesheets|javascripts|images|fonts)+\/(.+)$/;
  assetsMatched = detectAssets.exec(req.url);
  if (assetsMatched != null) {
    req.url = assetsMatched[0];
  }
  return staticMiddleware(req, res, function(err) {
    return next(err);
  });
};

GB = 1024 * 1024 * 1024;

config = {
  common: {
    set: {
      'view engine': getTemplateExt(),
      'views': path.resolve(__dirname, 'views')
    },
    engine: {
      js: function(path, locales, callback) {
        return callback(null, require(path)(locales));
      }
    },
    use: [americano.bodyParser(), staticMiddleware, publicStatic],
    afterStart: function(app, server) {
      return app.use(errorHandler);
    }
  },
  development: [americano.logger('dev')],
  production: [americano.logger('short')],
  plugins: ['cozydb']
};

module.exports = config;
