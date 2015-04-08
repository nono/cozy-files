var jade = require('jade/runtime');
module.exports = function template(locals) {
var buf = [];
var jade_mixins = {};
var jade_interp;
;var locals_for_with = (locals || {});(function (name, url, localization, displayName) {
buf.push("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width\"><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"></head><body><table cellspacing=\"0\" style=\"border-radius: 5px; border: 5px solid #34A6FF; margin: auto; width: 75%; padding: 20px 20px 10px 20px\"><tr><th style=\"color: #34A6FF; font-size: 20px\">Le contenu du dossier \"" + (jade.escape((jade_interp = name) == null ? '' : jade_interp)) + "\" a changé.</th></tr><tr><td style=\"padding: 45px 0; text-align: center; font-size: 18px\"><a" + (jade.attr("href", url, true, true)) + " style=\"background: #34A6FF; color: #fff; padding: 8px; border-radius: 5px; text-decoration: none;\">" + (jade.escape((jade_interp = localization.t('link folder content')) == null ? '' : jade_interp)) + " !</a></td></tr><tr><td style=\"text-align: center;\">Pour vous désabonner de ces notifications,&nbsp;<a" + (jade.attr("href", url + '&notifications=false', true, true)) + " style=\"color: #34A6FF;\">cliquez ici</a>.</td></tr><tr><td style=\"text-align: right; font-size: 12px; padding-top: 20px;\">Envoyé depuis le&nbsp;<a href=\"http://cozy.io\" style=\"color: #34A6FF;\">Cozy</a>&nbsp;de " + (jade.escape((jade_interp = displayName) == null ? '' : jade_interp)) + ".</td></tr></table></body></html>");}.call(this,"name" in locals_for_with?locals_for_with.name:typeof name!=="undefined"?name:undefined,"url" in locals_for_with?locals_for_with.url:typeof url!=="undefined"?url:undefined,"localization" in locals_for_with?locals_for_with.localization:typeof localization!=="undefined"?localization:undefined,"displayName" in locals_for_with?locals_for_with.displayName:typeof displayName!=="undefined"?displayName:undefined));;return buf.join("");
}