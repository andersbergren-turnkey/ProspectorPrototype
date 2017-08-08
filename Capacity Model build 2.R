# Import packages ---------------------------------------------------------

library(tidyverse)
library(lubridate)
library(magrittr)
library(forcats)
library(mlr)
library(parallelMap)
library(parallel)

# Import data -------------------------------------------------------------

ORIGINAL <- read_csv("prepped.csv")

# Format data -------------------------------------------------------------

names(ORIGINAL) <- gsub(" ", "_", names(ORIGINAL))
names(ORIGINAL) <- make.names(names(ORIGINAL), unique = TRUE)

ORIGINAL %<>%
  filter(Is_Valid_Abilitec_ID == 1) %>%
  filter(Abilitec_Age <= 365 & Abilitec_Age >= 0) %>%
  filter(Turnkey_Standard_Bundle_Age <= 365 & Turnkey_Standard_Bundle_Age >= 0) %>%
  filter(Spend_1 > 0) %>%
  select(-X1,
         -Spend_2,
         -ProspectID,
         -Tenure_1,
         -Tenure_2,
         -Planholder_1,
         -Planholder_2,
         -RecordCount_1,
         -RecordCount_2,
         -Abilitec_ID,
         -Abilitec_ID_Append_Date,
         -Abilitec_Age,
         -Acxiom_Consumer_Append_Date,
         -Turnkey_Standard_Bundle_Age,
         -Turnkey_Standard_Bundle_Date,
         -Adult_Age_Ranges_Present_in_Household,
         -Apartment_Number,
         -Children.s_Age_Ranges_Present_in_Household,
         -First_Name,
         -First_Name_._1st_Individual,
         -First_Name_._2nd_Individual,
         -Household_Abilitec_ID,
         -InfoBase_Positive_Match_Indicator,
         -Mail_Order_Buyer_Categories,
         -Email,
         -Last_Name,
         -Postal_Code,
         -Ticketing_System_Account_ID,
         -Ticket_History_File_RecID,
         -ZipCode,
         -Is_Valid_Abilitec_ID,
         -Middle_Initial_._1st_Individual,
         -Middle_Initial_._2nd_Individual,
         -Name_._Gender_._1st_Individual,
         -Name_._Gender_._2nd_Individual,
         -Vehicle_._Truck.Motorcycle.RV_Owner,
         -Base_Record_Verification_Date,
         -Retail_Activity_Date_of_Last,
         -Credit_Card_Indicator,
         -Precision_Level,
         -Number_of_Sources,
         -Overall_Match_Indicator,
         -Occupation_._Detail_._Input_Individual,
         -Age_00_._02_Female:-Age_16_._17_Unknown_Gender, # Confirm that these ":" will remain in position for all files
         -Females_18.24:-Females_75.,
         -Males_18.24:-Males_75.,
         -Unknown_Gender_18.24:-Unknown_Gender_75.,
         -Business_Owner_._Accountant:-Vehicle_._Dominant_Lifestyle_Indicator_._Regular_Classification_.Mid.size_._Small.,
         -Purchase_0_._3_Months:-Purchase_7_._9_Months,
         -Retail_Purchases_._Categories,
         -Suppression_._Mail_._DMA,
         -Vehicle_._New_Used_Indicator_._1st_Vehicle,
         -Vehicle_._New_Used_Indicator_._2nd_Vehicle,
         -Personicx_Cluster_Code,
         -Personicx_Digital_Cluster_Code)

# Set missing data

ORIGINAL[ORIGINAL == -1] <- NA
ORIGINAL[ORIGINAL == "-1"] <- NA
ORIGINAL[ORIGINAL == -2] <- 0

# Special variable formatting

ORIGINAL %<>%
  mutate(Business_Owner = ifelse(is.na(Business_Owner), -1, Business_Owner))

ORIGINAL %<>%
  separate(Retail_Activity_Date_of_Last, c(4,6), into = c("RA_Year", "RA_Month", "RA_remove")) %>%
  mutate(RA_Year = as.numeric(RA_Year)) %>%
  mutate(RA_Month = as.numeric(RA_Month)) %>%
  mutate(Retail_Activity_Months_Since = (year(now()) - RA_Year)*12 + RA_Month) %>%
  select(-RA_remove,-RA_Year,-RA_Month)

# Format variable types

ORIGINAL %<>%
  mutate(Business_Owner = as.factor(Business_Owner)) %>%
  mutate(PersonicX_Cluster = as.factor(PersonicX_Cluster)) %>%
  mutate(PersonicX_Digital_Cluster = as.factor(PersonicX_Digital_Cluster)) %>%
  mutate(Education_._Input_Individual = as.factor(Education_._Input_Individual)) %>%
  mutate(Education_._1st_Individual = as.factor(Education_._1st_Individual)) %>%
  mutate(Education_._2nd_Individual = as.factor(Education_._2nd_Individual)) %>%
  mutate(Home_Property_Type = as.factor(Home_Property_Type)) %>%
  mutate(Occupation_._Input_Individual = as.factor(Occupation_._Input_Individual)) %>%
  mutate(Occupation_._1st_Individual = as.factor(Occupation_._1st_Individual)) %>%
  mutate(Occupation_._2nd_Individual = as.factor(Occupation_._2nd_Individual)) %>%
  mutate(Retail_Purchases_._Most_Frequent_Category = as.factor(Retail_Purchases_._Most_Frequent_Category)) %>%
  mutate(Vehicle_._Dominant_Lifestyle_Indicator = as.factor(Vehicle_._Dominant_Lifestyle_Indicator)) %>%
  mutate(Personicx_Group_Number = as.factor(Personicx_Group_Number)) %>%
  mutate(Personicx_Digital_Group_Number = as.factor(Personicx_Digital_Group_Number)) %>%
  mutate(Race_Code = as.factor(Race_Code)) %>%
  mutate(County = as.factor(County))

# Remove NA variables below missing data threshold
# Finds variables with more than 30% NAs and removed them from the model, the rest will be imputed
# May need to be adapted to forcibly keep specific variables even if they have more than 30% missing
NA_Remove_Threshold <- .3 #typically 0.3-0.5

ORIGINAL %<>%
  select_if(funs(mean(is.na(.)) < NA_Remove_Threshold))

# Create log spend variables
# Spend tends to be a power law distribution so this normalizes the target variable
ORIGINAL %<>%
  mutate(Spend_1.log = log10(Spend_1))

# Remove outliers (This is a very "forgiving" method just to remove the top handful of massive spends)
# Jeremy's old method may be more "in-tune" with realistic sport spends
IQR_Outlier_Threshhold <- 4 #typically 2-4

ORIGINAL %<>%
  filter(!Spend_1.log %in% boxplot.stats(Spend_1.log,coef = IQR_Outlier_Threshhold)$out)

# Impute missings ---------------------------------------------------------

ORIGINAL %<>%
  removeConstantFeatures(perc = .05) %>%
  impute(classes = list(numeric = imputeMean(), integer = imputeMean(), factor = imputeMode())) %>%
  .[[1]] %>%
  createDummyFeatures(method = "reference") %>%
  select(-Spend_1)

# Set task ----------------------------------------------------------------

O.log.task <- makeRegrTask(data = ORIGINAL,
                           target = "Spend_1.log",
                           id = "Log of Spend")

# Set learner -------------------------------------------------------------

xgb.lrn <- makeLearner("regr.xgboost",
                       nthread = detectCores(),
                       id = "xgboost")

# Tune learner ------------------------------------------------------------

CV.tune_setting = makeResampleDesc("CV", iters = 3)

### xgboost tuning ### (long run time)

# Try a seperate nrounds tuning prior to tuning other params

#  Set parameter search space
params <- makeParamSet(makeIntegerParam("max_depth",lower = 5L,upper = 10L),
                       makeIntegerParam("min_child_weight",lower = 1L,upper = 20L),
                       makeNumericParam("subsample",lower = 0.6,upper = 1),
                       makeNumericParam("eta",lower = 0.01,upper = 0.2),
                       makeNumericParam("colsample_bytree",lower = 0.5,upper = 1),
                       makeIntegerParam("nrounds",lower = 100L,upper = 300L),
                       makeDiscreteParam("gamma",values = c(0,0.1)))

# try a seperate gamma tuning after params are established

# establish an appropriate number of instances and times to run
ctrl.rand <- makeTuneControlRandom(maxit = 12)

# Run tuning
parallelStartSocket(cpus = detectCores())

xgb.tune <- tuneParams(learner = xgb.lrn,
                       task = O.log.task,
                       resampling = CV.tune_setting,
                       measures = rmse,
                       par.set = params,
                       control = ctrl.rand,
                       show.info = TRUE)

parallelStop()

xgb.tuned.lrn <- setHyperPars(xgb.lrn, par.vals = xgb.tune$x)

# Train model -------------------------------------------------------------

### Run training ###
parallelStartSocket(cpus = detectCores())

trained_model = train(xgb.tuned.lrn, O.log.task)

parallelStop()