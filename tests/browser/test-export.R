test_that("the export button downloads a PNG of the graph", {
  page <- local_widget_page(
    lineage_example(),
    # Record the download instead of performing it, so nothing lands on disk
    before_load = "
      window.__downloads = [];
      HTMLAnchorElement.prototype.click = function() {
        window.__downloads.push({ download: this.download, href: this.href });
      };
    "
  )

  mouse_click(page, js(page, "__t.center(__t.button('Download PNG'))"))

  wait_for(page, "window.__downloads.length === 1")
  expect_identical(js(page, "window.__downloads[0].download"), "lineage.png")
  expect_true(js(page, "window.__downloads[0].href.startsWith('data:image/png;base64,')"))

  size <- js(page, "new Promise(function(resolve, reject) {
    var img = new Image();
    img.onload = function() { resolve({ width: img.naturalWidth, height: img.naturalHeight }); };
    img.onerror = function() { reject(new Error('the exported PNG does not decode')); };
    img.src = window.__downloads[0].href;
  })")
  # 2x the node bounds plus padding, never above 4096px a side
  expect_gt(size$width, 1000)
  expect_lte(size$width, 4096)
  expect_gt(size$height, 500)
  expect_lte(size$height, 4096)
  expect_identical(page$problems$seen, character())
})
