#' Download and crop the National Land Cover Database.
#'
#' \code{get_nlcd} returns a \code{RasterLayer} of NLCD data cropped to a given
#' template study area.
#'
#' @param template A Raster* or Spatial* object to serve 
#' as a template for cropping.
#' @param label A character string naming the study area.
#' @param year An integer representing the year of desired NLCD product.
#' Acceptable values are 2011 (default), 2006, and 2001.
#' @param dataset A character string representing type of the NLCD product.
#' Acceptable values are 'landcover' (default), 'impervious', and 'canopy'.
#' As of February 7, 2018, the canopy data for 2006 are not available through the National Map Staged datasets,
#' and so aren't available in FedData.
#' @param raw.dir A character string indicating where raw downloaded files should be put.
#' The directory will be created if missing. Defaults to './RAW/NLCD/'.
#' @param extraction.dir A character string indicating where the extracted and cropped DEM should be put.
#' The directory will be created if missing. Defaults to './EXTRACTIONS/NLCD/'.
#' @param raster.options a vector of options for raster::writeRaster. 
#' @param force.redo If an extraction for this template and label already exists, should a new one be created?
#' @return A \code{RasterLayer} DEM cropped to the extent of the template.
#' @export
#' @importFrom magrittr %>%
#' @importFrom foreach foreach %do%
#' @importFrom readr write_lines
#' @importFrom stringr str_c
#' @examples
#' \dontrun{
#' # Extract data for the Village Ecodynamics Project 'VEPIIN' study area:
#' # http://village.anth.wsu.edu
#' vepPolygon <- polygon_from_extent(raster::extent(672800,740000,4102000,4170000), 
#'      proj4string='+proj=utm +datum=NAD83 +zone=12')
#' 
#' # Get the NLCD (USA ONLY)
#' # Returns a raster
#' NLCD <- get_nlcd(template=vepPolygon, label='VEPIIN')
#' 
#' # Plot with raster::plot
#' plot(NLCD)
#' }
get_nlcd <- function(template,
                    label,
                    year = 2011,
                    dataset = "landcover",
                    raw.dir = "./RAW/NLCD",
                    extraction.dir = paste0("./EXTRACTIONS/", label, "/NLCD"),
                    raster.options = c("COMPRESS=DEFLATE",
                                       "ZLEVEL=9",
                                       "INTERLEAVE=BAND"),
                    force.redo = F) {
  
  raw.dir <- normalizePath(paste0(raw.dir,"/."), mustWork = FALSE)  
  extraction.dir <- normalizePath(paste0(extraction.dir,"/."), mustWork = FALSE)  
  
  dir.create(raw.dir, showWarnings = FALSE, recursive = TRUE)
  dir.create(extraction.dir, showWarnings = FALSE, recursive = TRUE)
 
  if (file.exists(paste0(extraction.dir, "/", label, "_NLCD_", year,"_",dataset, ".tif")) & !force.redo) {
    return(raster::raster(paste0(extraction.dir, "/", label, "_NLCD_", year,"_",dataset, ".tif")))
  }
   
  template <- template %<>%
    polygon_from_extent()
  
  # data(nlcd_tiles, package = "FedData")
  
  nlcd_tiles <- FedData::nlcd_tiles
  
  template.latlon <- template %>%
    sp::spTransform(raster::projection(nlcd_tiles))
  
  tile.ids <- nlcd_tiles$Name[!is.na((nlcd_tiles %over% template.latlon))]
  
  tile.ids <- tile.ids[!is.na(tile.ids)]
  tile.ids <- unique(tile.ids)
  
  message("Area of interest includes ", length(tile.ids), " NLCD tile(s).")
  
  # Download and crop tiles
  tiles <- lapply(tile.ids, function(tile) {
    return(get_nlcd_tile(template = template,
                         year = year,
                         dataset = dataset,
                         tileName = tile,
                         raw.dir = raw.dir))
  })
  names(tiles) <- tile.ids
  
  if(all(sapply(tiles, is.null))){
    stop("No NLCD tiles are available for your study area. Please check your input data and internet connection.")
  }
  tiles <- tiles[which(!sapply(tiles, is.null))] 
  
  atts <- tiles[[1]]@data@attributes
  leg <- tiles[[1]]@legend
  
  # Mosaic all tiles
  if (length(tiles) > 1) {
    message("Mosaicking NLCD tiles.")
    utils::flush.console()
    
    # tiles$fun <- mean
    names(tiles)[1:2] <- c("x", "y")
    tiles <- do.call(raster::merge, tiles)
    
    gc()
    
    tiles %<>%
      raster::as.factor()
    
   tiles@data@attributes <- atts
   tiles@legend <- leg
    
  } else {
    tiles <- tiles[[1]]
  }
  
  tiles <- tryCatch(tiles %>% raster::crop(y = template %>% sp::spTransform(CRSobj = tiles %>% raster::projection()), snap = "out"), 
                    error = function(e) {
                      tiles %>% raster::crop(y = template %>% sp::spTransform(CRSobj = tiles %>% raster::projection()))
                    })
  
  raster::writeRaster(tiles,
                      paste0(extraction.dir, "/", label, "_NLCD_", year,"_",dataset, ".tif"),
                      datatype = "INT1U",
                      options = raster.options,
                      overwrite = T,
                      setStatistics = FALSE)
  
  # Save the PAM attributes file
  if(dataset == "landcover"){
    # data(nlcd_landcover_pam, package = "FedData")
    nlcd_landcover_pam <- FedData::nlcd_landcover_pam
    readr::write_lines(nlcd_landcover_pam,
                       paste0(extraction.dir, "/", label, "_NLCD_", year,"_",dataset, ".tif.aux.xml"))
  }else if(dataset == "canopy"){
    # data(nlcd_canopy_pam, package = "FedData")
    nlcd_canopy_pam <- FedData::nlcd_canopy_pam
    readr::write_lines(nlcd_canopy_pam,
                       paste0(extraction.dir, "/", label, "_NLCD_", year,"_",dataset, ".tif.aux.xml"))
  }else if(dataset == "impervious"){
    # data(nlcd_impervious_pam, package = "FedData")
    nlcd_impervious_pam <- FedData::nlcd_impervious_pam
    readr::write_lines(nlcd_impervious_pam,
                       paste0(extraction.dir, "/", label, "_NLCD_", year,"_",dataset, ".tif.aux.xml"))
  }

  return(tiles)
}

#' Download a zipped tile from the National Land Cover Database.
#'
#' Tiles are 3x3 degree.
#' Tiles are downloaded in zipped geotiff format. \code{download_nlcd_tile} returns the path to the downloaded zip file.
#'
#' @param year An integer representing the year of desired NLCD product. Acceptable values are 2011 (default), 2006, and 2001.
#' @param dataset A character string representing type of the NLCD product. Acceptable values are landcover' (default), 'impervious', and 'canopy'.
#' @param tileName An character string representing tile to be downloaded. Will be of the form 'NxxWxxx', with the 'x' values as numbers.
#' @param raw.dir A character string indicating where raw downloaded files should be put.
#' The directory will be created if missing. Defaults to './RAW/NLCD/'.
#' @return A character string representing the full local path of the downloaded directory.
#' @export
#' @keywords internal
download_nlcd_tile <- function(year = 2011,
                               dataset = "landcover",
                               tileName,
                               raw.dir) {
  
  if(dataset == "landcover"){
    dataset_abbr <- "LC"
  }else if(dataset == "impervious"){
    dataset_abbr <- "IMP"
  }else if(dataset == "canopy"){
    dataset_abbr <- "CAN"
  }else{
    stop("Parameter 'dataset' must be one of 'landcover', 'impervious', or 'canopy'.")
  }
  
  destdir <- raw.dir
  
  dir.create(destdir, showWarnings = FALSE, recursive = TRUE)
  
  url <- paste0("https://prd-tnm.s3.amazonaws.com/StagedProducts/NLCD/data/",
                year, "/",
                dataset,
                "/3x3/NLCD",
                year, "_",
                dataset_abbr, "_",
                tileName,
                ".zip")
  download_data(url = url, destdir = destdir)
  
  return(normalizePath(paste0(destdir,"/", basename(url))))
}

#' Download and crop a tile from the National Land Cover Database.
#'
#' \code{get_nlcd_tile} returns a \code{RasterLayer} cropped within the specified \code{template}.
#' If template is not provided, returns the entire NLCD tile.
#' 
#' @param template A \code{Raster*} or \code{Spatial*} object to serve 
#' as a template for cropping. If missing, entire tile is returned.
#' @param year An integer representing the year of desired NLCD product. Acceptable values are 2011 (default), 2006, and 2001.
#' @param dataset A character string representing type of the NLCD product. Acceptable values are landcover' (default), 'impervious', and 'canopy'.
#' @param tileName An character string representing tile to be downloaded. Will be of the form 'NxxWxxx', with the 'x' values as numbers.
#' @param raw.dir A character string indicating where raw downloaded files should be put.
#' The directory will be created by \code{download_nlcd_tile} if missing. Defaults to './RAW/NLCD/'.
#' @return A \code{RasterLayer} cropped within the specified \code{template}.
#' @export
#' @importFrom magrittr %>%
#' @keywords internal
get_nlcd_tile <- function(template = NULL,
                          year = 2011,
                          dataset = "landcover",
                          tileName,
                          raw.dir) {
  
  if(dataset == "landcover"){
    dataset_abbr <- "LC"
  }else if(dataset == "impervious"){
    dataset_abbr <- "IMP"
  }else if(dataset == "canopy"){
    dataset_abbr <- "CAN"
  }else{
    stop("Parameter 'dataset' must be one of 'landcover', 'impervious', or 'canopy'.")
  }
  
  tmpdir <- tempfile()
  if (!dir.create(tmpdir)) 
    stop("failed to create my temporary directory")
  
  message("(Down)Loading NLCD tile: ", tileName)
  
  file <- download_nlcd_tile(year = year,
                             dataset = dataset,
                             tileName = tileName,
                             raw.dir = raw.dir)
  
  tryCatch(utils::unzip(file, exdir = tmpdir),
           warning = function(w){
             if(grepl("extracting from zip file",w$message) & !grepl("error -1 in extracting from zip file",w$message)){
               stop("nlcd file ",file," corrupt or incomplete. Please delete the file and try again.")
             }
           })
  
  tile <- tmpdir %>%
    list.files(pattern = "\\.tif$",
               full.names = TRUE) %>%
    raster::raster() %>%
    raster::readAll()
  
  if (!is.null(template)) {
    
    tile <- tryCatch(tile %>% 
                       raster::crop(y = template %>% 
                                             sp::spTransform(CRSobj = tile %>% 
                                                               raster::projection()), 
                                           snap = "out"), 
                     error = function(e) {
                       tile %>% 
                         raster::crop(y = template %>% 
                                        sp::spTransform(CRSobj = tile %>% 
                                                          raster::projection()))
                     })
  }
  
  # tile <- tile * 1
  
  unlink(tmpdir, recursive = TRUE)
  
  return(tile)
}

#' The NLCD tiles SpatialPolygonsDataFrame.
#'
#' A dataset containing the NLCD tiles.
#'
#' @format A SpatialPolygonsDataFrame with 203 features and 1 variable:
#' \describe{
#'   \item{Name}{the name of the tile}
#' }
"nlcd_tiles"

#' The NLCD landcover PAM attributes.
#'
#' A dataset containing the PAM attributes.
#'
"nlcd_landcover_pam"

#' The NLCD canopy PAM attributes.
#'
#' A dataset containing the PAM attributes.
#'
"nlcd_canopy_pam"

#' The NLCD impervious PAM attributes.
#'
#' A dataset containing the PAM attributes.
#'
"nlcd_impervious_pam"

#' NLCD colour map palettes
#'
#' @return A data frame with official class descriptions and hexencoded rgb(a) colour values
#' @importFrom raster values
#' @importFrom dplyr filter
#' @export
#' @references \url{https://www.mrlc.gov/nlcd11_leg.php}
#' @examples
#' \dontrun{
#' # Extract data for the Village Ecodynamics Project 'VEPIIN' study area:
#' # http://village.anth.wsu.edu
#' vepPolygon <- polygon_from_extent(raster::extent(672800,740000,4102000,4170000), 
#'      proj4string='+proj=utm +datum=NAD83 +zone=12')
#' 
#' NLCD <- get_nlcd(template=vepPolygon, label='VEPIIN')
#' NLCD <- as.matrix(table(raster::values(NLCD)))
#' cols <- dplyr::filter(pal_nlcd(), code %in% row.names(NLCD))

#' par(xpd = TRUE, mar = c(10, 3, 2, 1))
#' barplot(NLCD, beside = FALSE, col = cols$color) 
#' legend("bottom", legend = cols$description, fill = cols$color, 
#'        ncol = 2, inset = c(0, -0.6))
#' }
pal_nlcd <- function() {
  data.frame(
    class = c("water", "water",
              "developed", "developed", "developed", "developed",
              "barren",
              "forest", "forest", "forest",
              "shrubland", "shrubland",
              "herbaceous", "herbaceous", "herbaceous", "herbaceous",
              "planted", "planted",
              "wetlands", "wetlands"),
    code = as.character(c(11, 12,
             21, 22, 23, 24,
             31,
             41, 42, 43,
             51, 52,
             71, 72, 73, 74,
             81, 82,
             90, 95)),
    description = c("Open Water", "Perennial Ice/Snow",
                    "Developed, Open Space", "Developed, Low Intensity", "Developed, Medium Intensity", "Developed, High Intensity",
                    "Barren Land (Rock/Sand/Clay)",
                    "Deciduous Forest", "Evergreen Forest", "Mixed Forest",
                    "Dwarf Scrub", "Scrub/Shrub",
                    "Grassland/Herbaceous", "Sedge/Herbaceuous", "Lichens", "Moss",
                    "Pasture/Hay", "Cultivated Crops",
                    "Woody Wetlands", "Emergent Herbaceous Wetlands"),
    color = c("#476BA0", "#D1DDF9",
              "#DDC9C9", "#D89382", "#ED0000", "#AA0000",
              "#B2ADA3",
              "#68AA63", "#1C6330", "#B5C98E",
              "#A58C30", "#CCBA7C",
              "#E2E2C1", "#C9C977", "#99C147", "#77AD93",
              "#DBD83D", "#AA7028",
              "#BAD8EA", "#70A3BA"),
    stringsAsFactors = FALSE)
}
