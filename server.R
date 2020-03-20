
needed_packages <- c(
  "shiny"
, "ggplot2"
, "deSolve"
, "plyr"
, "magrittr"
, "scales"
, "lubridate"
, "dplyr"
, "pomp"
, "reshape2"
, "shinythemes"
, "shinydashboard"
)

## Check if the packages are installed. *If they are not install them*, then load them
if (length(setdiff(needed_packages, rownames(installed.packages()))) > 0) {
  install.packages(setdiff(needed_packages, rownames(installed.packages())))  
}

lapply(needed_packages, require, character.only = TRUE)

source("ggplot_theme.R")

function(input, output) {
  
  epi.dat <- reactive({
  
sir_step <- Csnippet("
                     double betat;
                     if(intervention == 2 & thresh_crossed == 1){ // 2 is for threshhold intervention
                       betat =  beta0*thresh_int_level; 
                     }
                     else if(intervention == 1) betat = beta0*contact; // 1 is for social distancing
                     else betat = beta0; // everything else is no intervention
                     double dSE = rbinom(S, 1-exp(-betat*(Ca*Ia/N + Cp*Ip/N + Cm*Im/N + Cs*Is/N)*dt)); 
                     double rateE[2];
                     double dE_all[2];
                     rateE[0] = alpha*gamma; // going to asymtomatic
                     rateE[1] = (1-alpha)*gamma; // going to presymptomatic
                     reulermultinom(2, E, rateE, dt, &dE_all);
                     double dEIa = dE_all[0];
                     double dEIp = dE_all[1];
                     double dIaR = rbinom(Ia, 1 - exp(-lambda_a*dt));
                     double rateIp[2];
                     double dIp_all[2];
                     rateIp[0] = mu*rho; // going to minor symptomatic
                     rateIp[1] = (1-mu)*rho; // going to sever symptomatic
                     reulermultinom(2, Ip, rateIp, dt, &dIp_all);
                     double dIpIm = dIp_all[0];
                     double dIpIs = dIp_all[1];
                     double dIsH = rbinom(Is, 1 - exp(-lambda_s*dt));
                     double dImR = rbinom(Im, 1 - exp(-lambda_m*dt));
                     double rateH[2];
                     double dH_all[2];
                     rateH[0] = delta*lambda_h;
                     rateH[1] = (1-delta)*lambda_h;
                     reulermultinom(2, H, rateH, dt, &dH_all);
                     double dHD = dH_all[0];
                     double dHR = dH_all[1];
                     
                     S  -= dSE; // susceptible 
                     E  += dSE - dEIa - dEIp; // exposed
                     Ia += dEIa - dIaR; // infectious and asymptomatic
                     Ip += dEIp - dIpIs - dIpIm; // infectious and pre-symptomatic
                     Is += dIpIs - dIsH; // infectious and severe symptoms (that will be hospitalized)
                     Im += dIpIm - dImR; // infectious and minor symptoms
                     H  += dIsH - dHD - dHR; // hospitalized
                     R  += dHR + dImR + dIaR; // recovered
                     D  += dHD; // fatalities
                     sympt_new  +=  dIpIs + dIpIm;
                     H_new += dIsH;
                     thresh_crossed = 0; 
                     if(intervention == 2 & H >= thresh_H) thresh_crossed = 1;
                     ")

# define the initial set up, currently, every is susceptible except the exposed people
sir_init <- Csnippet("
                     S = N-E0;
                     E = E0;
                     Ia = 0;
                     Ip = 0;
                     Is = 0;
                     Im = 0;
                     H = 0;
                     R = 0;
                     D = 0;
                     sympt_new = 0;
                     H_new = 0;
                     thresh_crossed = 0;
                     ")
  
sim_length <- as.Date("2020-12-01") - as.Date("2019-12-01")
dat        <- data.frame(
  day = 0:sim_length
, B   = rep(0, sim_length + 1)
  )

## in Wuhan, the intervention started around January 23
int_start  <- as.Date("2020-01-23") - as.Date("2019-12-01") 
int_length <- sim_length - int_start + 1 
int_level  <- 0.3

## use the intervention info to construct a covariate table for use in the pomp object
contact_rate <- covariate_table(
  day     = 0:(sim_length)
, contact = c(rep(1, int_start)
    , rep(int_level, int_length)
    , rep(1, sim_length - int_start - int_length + 1)
  )
, order   = "constant"
, times   = "day"
  )  

covid <- dat %>%
  pomp(
    time = "day",
    t0 = 0,
    covar = contact_rate,
    rprocess=euler(sir_step,delta.t=1/6),
    rinit=sir_init,
    accumvars= c("sympt_new", "H_new"), # accumulate H until it gets measured, then zero it
    paramnames=c("beta0",
                 "Ca", "Cp", "Cs", "Cm",
                 "alpha",
                 "gamma", 
                 "lambda_a", "lambda_s","lambda_m", "lambda_h",
                 "delta",
                 "mu",
                 "rho", 
                 "N", # population size
                 "E0", # number of people initially exposed 
                 "intervention",
                 "thresh_H",
                 "thresh_int_level"),
    statenames=c("S","E","Ia", 
                 "Ip","Is","Im",
                 "R", "H","D", 
                 "sympt_new", "H_new",
                 "thresh_crossed")
  ) 

sim = covid %>%
  simulate(params=c(beta0 = 0.5, # without intervention beta for all categories
                    Ca = 1, Cp = 1, Cs = 1, Cm = 1, # category specific contact rates
                    alpha = 1/3, # fraction of cases asymptomatic
                    gamma = 1/5.2, # 1 over time in exposed class
                    lambda_a = 1/7, # 1/time for asympomatic to recover
                    lambda_s = 1/4, # 1/time for severely symptomatic to go to the hospitl 
                    lambda_m = 1/7, # 1/time for minorly sympomatic to recover
                    lambda_h = 1/10.7, # 1/time  to leaving hospital  
                    delta = 0.2, # fraction of hospitalized cases that are fatal
                    mu = 19/20, # fraction of cases that are minor
                    rho = 1/0.5, # 1/time in pre-symptomatic 
                    N=59.02e6, # population size 
                    E0 = 10,  # initially exposed
                    intervention = 2, # 1 is for social distancing, 2 is for threshhold based, currently threshH is based on 
                    thresh_H = 10, # currently thressholding on total people in the hospital
                    thresh_int_level = 0.01), # multiplier on beta when the thresshold causes the intervention to kick in
           nsim=10,format="d",include.data=F) %>%
# calulate the median of the simulations
  {rbind(.,
         group_by(., day) %>%
           select(-.id) %>%
           summarise_all(median) %>%
                    mutate(.id = "median"))} 

epi.out <- sim %>% mutate(date = as.Date("2019-12-01") + day)

  list(
    epi.out = epi.out
    )
  
  })

  output$graph1 <- renderPlot({ 
    
  ggplot(epi.dat()[["epi.out"]]) + geom_line(aes(x=date, 
                y = Is + Im + Ia + Ip,
                group=.id, 
                color = .id == "median")) + 
  scale_x_date(labels = date_format("%Y-%b")) +
  # geom_vline(xintercept = as.Date("2020-01-23"), col = "red") + # current intervention date for social distancing
  guides(color=FALSE)+
  scale_color_manual(values=c("#D5D5D3", "#24281A"))
    
    })
  
  output$graph2 <- renderPlot({ 
    ggplot()    
    })
  
  output$graph3 <- renderPlot({ 
    
  epi.out.s <- epi.dat()[["epi.out"]] %>% 
  filter(.id != "median") %>%
  group_by(.id) %>% 
  dplyr::summarize(
    peak_val  = max(Ia + Ip + Is)
  , peak_time = which((Ia + Ip + Is) == max(Ia + Ip + Is))[1]
  ) %>% tidyr::pivot_longer(c(peak_val, peak_time), names_to = "Est")
    
  epi.out.s %>% ggplot(aes(Est, value)) + geom_boxplot()
     
    })
  
  output$graph4 <- renderPlot({ 
    ggplot()   
    })
  
 output$datadown <- downloadHandler(

    # This function returns a string which tells the client
    # browser what name to use when saving the file.
    filename = function() {
		  paste(paste("epi.out", paste(strsplit(as.character(Sys.Date()), split = " +")[[1]], collapse = "_"), sep = "_"), "csv", sep = ".")
	  },

    # This function should write data to a file given to it by
    # the argument 'file'.
    content = function(file) {
      write.csv(epi.dat()[["epi.out"]], file, row.names = FALSE)
    }
  )
  
}
