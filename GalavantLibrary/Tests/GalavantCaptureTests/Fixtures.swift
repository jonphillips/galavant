/// Hand-written page fixtures that exercise each extraction layer. Realistic
/// enough to catch regressions, small enough to read. No network, no files.
enum Fixtures {
  static let jsonLDRestaurant = """
    <html><head>
    <title>Noma — Yelp</title>
    <script type="application/ld+json">
    {
      "@context": "https://schema.org",
      "@type": "Restaurant",
      "name": "Noma",
      "description": "Three-Michelin-star Nordic restaurant.",
      "telephone": "+45 32 96 32 97",
      "email": "book@noma.dk",
      "url": "https://noma.dk",
      "image": "https://noma.dk/hero.jpg",
      "sameAs": ["https://www.instagram.com/nomacph", "https://facebook.com/noma"],
      "address": {
        "@type": "PostalAddress",
        "streetAddress": "Refshalevej 96",
        "addressLocality": "Copenhagen",
        "addressRegion": "Hovedstaden",
        "postalCode": "1432",
        "addressCountry": "DK"
      },
      "geo": { "@type": "GeoCoordinates", "latitude": 55.6839, "longitude": 12.6109 },
      "openingHoursSpecification": [
        { "@type": "OpeningHoursSpecification", "dayOfWeek": ["Tuesday", "Wednesday"], "opens": "17:00", "closes": "23:00" }
      ]
    }
    </script>
    </head><body></body></html>
    """

  static let openGraph = """
    <html><head>
    <title>Tivoli Gardens — Official Site</title>
    <meta property="og:title" content="Tivoli Gardens">
    <meta property="og:description" content="Historic amusement park in central Copenhagen.">
    <meta property="og:url" content="https://www.tivoli.dk">
    <meta property="og:image" content="https://www.tivoli.dk/og.jpg">
    <meta property="place:location:latitude" content="55.6736">
    <meta property="place:location:longitude" content="12.5681">
    <meta property="business:contact_data:street_address" content="Vesterbrogade 3">
    <meta property="business:contact_data:locality" content="Copenhagen">
    <meta property="business:contact_data:phone_number" content="+45 33 15 10 01">
    </head><body></body></html>
    """

  /// JSON-LD + microdata agree on "Real Name" (2 votes); OG offers "SEO Junk
  /// Name" (1 vote). Voting must pick the corroborated value.
  static let votingConflict = """
    <html><head>
    <script type="application/ld+json">{"@type":"Restaurant","name":"Real Name"}</script>
    <meta property="og:title" content="SEO Junk Name">
    </head>
    <body itemscope itemtype="https://schema.org/Restaurant">
      <span itemprop="name">Real Name</span>
    </body></html>
    """

  static let microdataHotel = """
    <html><body itemscope itemtype="https://schema.org/Hotel">
      <h1 itemprop="name">Hotel Danmark</h1>
      <span itemprop="telephone">+45 11 22 33 44</span>
      <div itemprop="address" itemscope itemtype="https://schema.org/PostalAddress">
        <span itemprop="streetAddress">Vester Voldgade 89</span>
        <span itemprop="addressLocality">Copenhagen</span>
      </div>
      <a itemprop="url" href="https://hoteldanmark.dk">Official site</a>
    </body></html>
    """

  /// One keeper plus a logo, a tracking pixel (bad extension), and a relative
  /// path that must resolve against the source URL.
  static let mixedImages = """
    <html><head>
    <script type="application/ld+json">{
      "@type": "Restaurant",
      "name": "X",
      "image": ["/photos/main.jpg", "https://cdn.example.com/logo.png", "https://tracker.com/p.gif"]
    }</script>
    </head><body></body></html>
    """

  /// A JS-driven page: the `og:image` is a plain hero, but the real gallery photos
  /// live in lazy-load attributes, srcset/`<picture>`, CSS backgrounds (inline,
  /// `<style>`, and `data-bg`), and a `<noscript>` fallback. A sprite/icon must
  /// still be filtered.
  static let richBodyImages = """
    <html><head>
    <meta property="og:image" content="https://place.com/og.jpg">
    <style>.hero { background-image: url(https://place.com/style-block.jpg); }</style>
    </head>
    <body>
      <div style="background-image: url('https://place.com/inline-bg.jpg')"></div>
      <img data-src="https://place.com/lazy.jpg">
      <img srcset="https://place.com/small.jpg 480w, https://place.com/large.jpg 1200w">
      <picture><source srcset="https://place.com/picture.webp"></picture>
      <div data-bg="https://place.com/data-bg.jpg"></div>
      <img data-src="https://place.com/icon-sprite.png">
      <noscript><img src="https://place.com/noscript.jpg"></noscript>
    </body></html>
    """

  static let brokenJSONLDWithOG = """
    <html><head>
    <script type="application/ld+json">{ this is not valid json ]</script>
    <meta property="og:title" content="Still Works">
    </head><body></body></html>
    """
}
