/*
 * Share-extension preprocessing (V1 `ExtensionPreProcessing.js` pattern): Safari
 * runs this in the page and hands the extension the *rendered* DOM — post-
 * JavaScript HTML, the page URL, and title. That rendered HTML is what the
 * GalavantCapture engine parses; it beats a raw URLSession fetch for JS-heavy
 * pages. Keys here arrive in the extension under
 * NSExtensionJavaScriptPreprocessingResultsKey.
 */
var ExtensionPreprocessingJS = function () {};

ExtensionPreprocessingJS.prototype = {
  run: function (args) {
    args.completionFunction({
      url: document.URL,
      title: document.title,
      html: document.documentElement.outerHTML,
    });
  },
  finalize: function (args) {},
};

var ExtensionPreprocessingJS = new ExtensionPreprocessingJS();
