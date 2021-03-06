######################################################################
## R code generating graphs and numbers for the multivariate and scan
## statistics sections of the book chapter "Prospective Detection of
## Outbreaks" by B. Allévius and M. Höhle in the Handbook of
## Infectious Disease Data Analysis.
##
## Author: Benjamin Allévius <http://www.su.se/english/profiles/bekj9674-1.194276>
## Affiliation: Department of Mathematics, Stockholm University, Sweden
##
## Date: 2017-11-10
######################################################################

library(readr)
library(dplyr)
library(stringr)
library(tidyr)
library(lubridate)
library(magrittr)
library(ggplot2)
library(scales)


figure_path <- "./figures"

Sys.setlocale("LC_TIME", "en_US.UTF-8")

# Munge data ===================================================================

# Menigococcal data from surveillance
library(surveillance)
data(imdepi)

# Aggregate across event types, age and gender
meningo_cases <- imdepi$events@data %>% as_tibble %>% mutate(count = 1L)

# Grab coordinates
meningo_coords <- coordinates(imdepi$events)
meningo_cases %<>%
  mutate(x_coord = meningo_coords[, 1], y_coord = meningo_coords[, 2])

# Add dates and remove unneeded columns
meningo_cases %<>%
  mutate(day = ceiling(time),
         date = as.Date("2001-12-31") + lubridate::days(day), # Exact start date is unknown
         year = as.integer(lubridate::year(date)),
         month = as.integer(month(date))) %>%
  select(-eps.t, -eps.s, -.obsInfLength, -.sources, -.bdist, -.influenceRegion)

# Munge district-level data
district_data <- imdepi$stgrid %>% as_tibble %>%
  mutate(population = as.integer(popdensity * area))

tile_location <- tibble(tile = unique(district_data$tile),
                        location = 1:length(unique(district_data$tile)))
district_data <- left_join(district_data, tile_location, by = "tile")

# Get the total population (population is constant across time)
total_pop <- sum((district_data %>% filter(BLOCK == 1))$population)

# Monthly counts with covariates
meningo_monthly <- meningo_cases %>% select(tile, BLOCK) %>%
  mutate(count = 1L) %>%
  group_by(tile, BLOCK) %>%
  summarize(count = n()) %>%
  ungroup %>%
  right_join(district_data %>% select(tile, location, BLOCK, area, popdensity, population),
             by = c("tile", "BLOCK")) %>%
  mutate(count = ifelse(is.na(count), 0L, count)) %>%
  mutate(total_pop = total_pop) %>%
  rename(time = BLOCK) %>%
  arrange(location, time) %>%
  mutate(year = 2002 + floor((time - 1) / 12),
         month = ifelse(time %% 12 == 0, 12, time %% 12),
         date = as.Date(paste(year, month, "01", sep = "-")))

# Extract dates
dates <- (meningo_monthly %>% filter(tile == "01001") %>% select(date))$date

# Hotelling T^2 ================================================================
# library(RiskPortfolios)

# Aggregate counts to state level
state_counts <- meningo_monthly %>%
  mutate(state = str_sub(as.character(tile), end = 2)) %>%
  group_by(state, time, date) %>%
  summarize(area = sum(area),
            population = sum(population),
            count = sum(count)) %>%
  ungroup %>%
  mutate(popdensity = population / area,
         total_pop = total_pop)

# Put counts in matrix form
state_count_mat <- reshape2::acast(state_counts,
                                   time ~ state,
                                   value.var = "count")

# Define surveillance period
t2_start <- 12 * 2 + 1
t2_end <- 12 * 4
t2_length <- t2_end - t2_start + 1

# Parameters and storage for Hotelling's T2 method
t2_p <- ncol(state_count_mat)
t2_alpha <- 1 / (12 * 3)
t2_df <- tibble(date = dates[t2_start:t2_end],
                obs = NA,
                crit = NA,
                pval = NA)

# Calculate the T2 statistic for each month of the surveillance period
idx <- 1
for (n in t2_start:t2_end) {
  # Simple approach
  state_means <- apply(state_count_mat[1:n, ], 2, mean)
  state_cov <- cov(state_count_mat[1:n, ])

  # Hotellings T^2
  v <- state_count_mat[n, ] - state_means
  t2 <- as.numeric(v %*% solve(state_cov, v))
  t2_df$obs[idx]  <- t2 #* (n - t2_p) / (t2_p * (n - 1))
  t2_df$crit[idx] <- qf(1 - t2_alpha, t2_p, n) * (t2_p * (n - 1)) / (n - t2_p)
  t2_df$pval[idx] <- pf(t2 * (n - t2_p) / (t2_p * (n - 1)), t2_p, n)

  idx <- idx + 1
}

t2_plot <- ggplot(t2_df) +
  geom_line(aes(x = date, y = obs)) +
  geom_line(aes(x = date, y = crit),
            color = "gray47", linetype = "dashed") +
  scale_x_date(date_breaks = "6 month",
               date_minor_breaks = "1 month",
               labels = date_format("%b-%Y")) +
  xlab("Date") + ylab(expression("T"^2)) +
  theme_bw()

# ggsave(paste0(figure_path, "/hot2.pdf"), t2_plot, width = 6, height = 2.5)

# Scan statistics ==============================================================
library(scanstatistics)

# Shapefile for the districts of Germany
load(system.file("shapes", "districtsD.RData", package = "surveillance"))

# Parameters for the scan statistic
zones <- coordinates(districtsD) %>% coords_to_knn(k = 15) %>% knn_zones
scan_length <- 6 # Scanning window covers last 6 months

# Parameters for the surveillance period
scan_start <- t2_start
scan_end <- t2_end
scan_mc <- 99
scan_alpha <- 1 / (12 * 5)

# Store replicate scan statistics
replicates <- rep(NA, (scan_end - scan_start + 1) * scan_mc)

# Kulldorff's scan statistic
scan_df <- tibble(date = dates[scan_start:scan_end],
                  score = NA,
                  crit = NA,
                  pval = NA,
                  zone = NA,
                  duration = NA,
                  relrisk_in = NA,
                  relrisk_out = NA)

# The Bayesian spatial scan statistic
bayscan_df <- tibble(date = dates[scan_start:scan_end],
                     MLC_prob = NA,
                     MLC_logBF = NA,
                     MLC_zone = NA,
                     MLC_duration = NA,
                     outbreak_prob = NA,
                     relrisk_MAP = NA)

relrisk_support <- seq(1, 15, by = 0.1)
prev_relrisk_prob <- rep(1, length(relrisk_support))

bayscan_relrisk <- matrix(NA,
                          length(scan_start:scan_end),
                          length(relrisk_support))

emp_pval <- function(observed, replicates) {
  (1 + observed) / (1 + length(replicates))
}

idx <- 1
for (i in scan_start:scan_end) {
  time_window <- seq(max(1, i - scan_length + 1), i, by = 1)
  obs_counts <- meningo_monthly %>% filter(time %in% time_window)

  # Kulldorff's scan statistic
  scan <- scan_pb_poisson(obs_counts, zones, n_mcsim = scan_mc)
  repl_idx <- ((idx-1) * scan_mc + 1):(idx * scan_mc)
  replicates[repl_idx] <- scan$replicates$score

  scan_df$score[idx] <- scan$MLC$score
  scan_df$crit[idx] <- quantile(replicates[1:tail(repl_idx, 1)],
                                1 - scan_alpha,
                                type = 8)
  scan_df$pval[idx] <- emp_pval(scan$MLC$score, replicates[1:tail(repl_idx, 1)])
  scan_df$zone[idx] <- scan$MLC$zone_number
  scan_df$duration[idx] <- scan$MLC$duration
  scan_df$relrisk_in[idx] <- scan$MLC$relrisk_in
  scan_df$relrisk_out[idx] <- scan$MLC$relrisk_out

  # The Bayesian spatial scan statistic
  bayscan <- scan <- scan_bayes_negbin(obs_counts, zones,
                                       outbreak_prob = 1e-7,
                                       inc_probs = prev_relrisk_prob,
                                       inc_values = relrisk_support)
  prev_relrisk_prob <- bayscan$posteriors$inc_posterior$inc_posterior

  bayscan_df$MLC_prob[idx] <- bayscan$MLC$posterior
  bayscan_df$MLC_logBF[idx] <- bayscan$posteriors$window_posteriors[1, 4]
  bayscan_df$MLC_zone[idx] <- bayscan$MLC$zone
  bayscan_df$MLC_duration[idx] <- bayscan$MLC$duration
  bayscan_df$outbreak_prob[idx] <- bayscan$posteriors$alt_posterior
  bayscan_df$relrisk_MAP[idx] <- relrisk_support[which.max(prev_relrisk_prob)]
  bayscan_relrisk[idx, ] <- prev_relrisk_prob

  print(paste0("idx = ", idx))
  idx <- idx + 1
}

# Plots for Kulldorff's scan statistic -----------------------------------------

# Plot the score of the MLC over time
scan_score_plot <- ggplot(gather(scan_df,
                                 key = "type", value = "value",
                                 score, crit)) +
  geom_line(aes(x = date, y = value, color = type, linetype = type)) +
  scale_x_date(date_breaks = "6 month",
               date_minor_breaks = "1 month",
               labels = date_format("%b-%Y")) +
  scale_color_manual(name  = "",
                     breaks=c("score", "crit"),
                     labels=c("Score", "Critical value"),
                     values = c("gray47", "black")) +
  scale_linetype_manual(name  = "",
                        breaks=c("score", "crit"),
                        labels=c("Score", "Critical value"),
                        values = c("dashed", "solid")) +
  xlab("Date") + ylab(expression(lambda[W])) +
  theme_bw() +
  theme(legend.position = c(0.9, 0.9),
        legend.background = element_rect(fill = "transparent"),
        legend.key = element_blank())

# ggsave(paste0(figure_path, "/scan_score.pdf"), scan_score_plot,
#        width = 6, height = 2.5)


# Calculate the overlap between clusters
zone_olap <- function(z1, z2) {
  length(base::intersect(z1, z2)) / length(base::union(z1, z2))
}

vec_zone_olap <- Vectorize(zone_olap, c("z1", "z2"))

zone_overlap <- rep(NA, nrow(scan_df) - 1)
for (i in 2:nrow(scan_df)) {
  zone_overlap[i-1] <- zone_olap(zones[[scan_df$zone[i - 1]]],
                                 zones[[scan_df$zone[i]]])
}

# Extract the MLC
MLC_zone <- zones[[scan_df$zone[which.max(scan_df$score)]]]

# Incidences per 100,000 people
meningo_incidence <- meningo_monthly %>%
  group_by(tile, location) %>%
  summarise(count = sum(count),
            population = population[1]) %>%
  ungroup %>%
  mutate(incidence = count * 100000 / population)

# Label the cluster
scan_clust <- districtsD@data %>%
  as_tibble %>%
  mutate(tile = as.factor(KEY),
         id = KEY,
         popdensity = POPULATION / AREA) %>%
  left_join(tile_location, by = "tile") %>%
  mutate(MLC = ifelse(location %in% MLC_zone, "Yes", "No")) %>%
  left_join(meningo_incidence, by = "tile")


# Make map data plotable
district_map <- fortify(districtsD) %>%
  as.tbl %>%
  left_join(scan_clust, by = "id") %>%
  mutate(state = substr(KEY, 1, 2))

cluster_state <- filter(district_map, MLC == "Yes" & order == 1)$state

district_map %<>%
  mutate(MLC_in_state = (state == cluster_state),
         MLC = factor(MLC, levels = c("Yes", "No")))


# Time series plot of observed scan statistic
scan_mlc_map <- ggplot(district_map %>% filter(MLC_in_state)) +
  theme_minimal() +
  geom_polygon(aes(x = long, y = lat, group = group, fill = MLC),
               color = "black") +
  labs(x = "", y = "") +
  theme(axis.title = element_blank(),
        axis.text = element_blank(),
        panel.grid = element_blank()) +
  scale_fill_manual(values = c("gray37", "white")) +
  theme(legend.position = "none") +
  # theme(legend.position=c(0.9, 0.35)) +
  coord_equal()

# ggsave(paste0(figure_path, "/scan_mlc.pdf"), scan_mlc_map,
#        width = 4, height = 3)

# Plots for the Bayesian scan statistic ----------------------------------------

bayscan_MLCprob <- ggplot(bayscan_df) +
  geom_line(aes(x = date, y = MLC_prob)) +
  scale_x_date(date_breaks = "6 month",
               date_minor_breaks = "1 month",
               labels = date_format("%b-%Y")) +
  xlab("Date") + ylab("MLC posterior") +
  ylim(0, 1) +
  theme_bw()

# ggsave(paste0(figure_path, "/bayscan_MLCprob.pdf"), bayscan_MLCprob,
#        width = 6, height = 2.5)

# Add first prior
bayscan_relrisk <- rbind(rep(1 / ncol(bayscan_relrisk), ncol(bayscan_relrisk)),
                         bayscan_relrisk)

matplot(x = relrisk_support,
        y = t(bayscan_relrisk),
        type = "l",
        ylab = "Posterior probability",
        xlab = "Relative risk")

# Last section =================================================================

# Parameters to surveillance::stcd
rad <- 75   # From Meyer2012
eps <- 0.2  # From Assuncao2009
thres <- 30 # = ARL0

# Filter data to correspond approximately to Reinhardt et al. (2008)
keep_idx <- meningo_cases$type == "B" &
            meningo_cases$date >= as.Date("2004-03-01") &
            meningo_cases$date < as.Date("2006-01-01")
stcd_cases <- meningo_cases[keep_idx, ]
stcd_coords <- coordinates(imdepi$events)[keep_idx, ]

# Run detection
stcd_res <- stcd(x = stcd_coords[, 1],
                 y = stcd_coords[, 2],
                 t = stcd_cases$time,
                 radius = rad, 
                 epsilon = eps, 
                 areaA = -1,
                 areaAcapBk = -1,
                 threshold = thres)

# Extract date of cluster start
stcd_start_day <- ceiling(stcd_res$idxCC)
stcd_cases$date[stcd_start_day]

# Extract date of cluster detection
stcd_detection_day <- ceiling(stcd_res$idxFA)
stcd_cases$date[stcd_detection_day]

# Extract centerpoint of start
center_coords <- stcd_coords[stcd_start_day, ]

# Extract name of district
center_tile <- stcd_cases[stcd_start_day, ]$tile
center_name <- district_map[district_map$tile == center_tile, "GEN"][1]

# Plot circle with radius as above, with data up to time stcd_res$idxFA
circle_fun <- function(center = center_coords,
                       r = 100, npoints = 100){
  tt <- seq(0,2*pi, length.out = npoints)
  xx <- center[1] + r * cos(tt)
  yy <- center[2] + r * sin(tt)
  return(data.frame(x = xx, y = yy))
}
outbreak_circle <- circle_fun()

stcd_map <- ggplot(district_map) +
  theme_minimal() +
  geom_polygon(aes(x = long, y = lat, group = group),
               color = "grey", fill = "white") +
  geom_point(aes(x = x_coord, y = y_coord),
             data = stcd_cases[1:stcd_detection_day, ],
             size = 2, shape = 17) +
  labs(x = "", y = "") +
  theme(axis.title = element_blank(),
        axis.text = element_blank(),
        panel.grid = element_blank()) +
  scale_fill_distiller(
    name = "MLC",
    palette = "YlGnBu",
    direction = 1,
    guide = guide_colorbar(direction = "vertical",
                           title.vjust = 0.4)) +
  geom_path(aes(x = x, y = y),
            data = outbreak_circle,
            color = "gray47") +
  coord_equal()

stcd_map

# ggsave(paste0(figure_path, "/stcd_map.pdf"), stcd_map, width = 4, height = 3)

