#' @title
#' Create \code{microtable} object to store and manage all the basic files.
#'
#' @description
#' This class is a wrapper for a series of operations on the input files and basic manipulations,
#' including microtable object creation, data trimming, data filtering, rarefaction based on Paul et al. (2013) <doi:10.1371/journal.pone.0061217>, taxonomic abundance calculation, 
#' alpha and beta diversity calculation based on the An et al. (2019) <doi:10.1016/j.geoderma.2018.09.035> and 
#' Lozupone et al. (2005) <doi:10.1128/AEM.71.12.8228–8235.2005> and other basic operations.\cr
#' \cr
#' Online tutorial: \href{https://chiliubio.github.io/microeco_tutorial/}{https://chiliubio.github.io/microeco_tutorial/} \cr
#' Download tutorial: \href{https://github.com/ChiLiubio/microeco_tutorial/releases}{https://github.com/ChiLiubio/microeco_tutorial/releases}
#' 
#' @export
microtable <- R6Class(classname = "microtable",
	public = list(
		#' @param otu_table data.frame; The feature abundance table; rownames are features (e.g. OTUs/ASVs/species/genes); column names are samples.
		#' @param sample_table data.frame; default NULL; The sample information table; rownames are samples; columns are sample metadata; 
		#' 	 If not provided, the function can generate a table automatically according to the sample names in otu_table.
		#' @param tax_table data.frame; default NULL; The taxonomic information table; rownames are features; column names are taxonomic classes.
		#' @param phylo_tree phylo; default NULL; The phylogenetic tree; use \code{read.tree} function in ape package for input.
		#' @param rep_fasta \code{DNAStringSet} or \code{list} format; default NULL; The representative sequences; 
		#'   use \code{read.fasta} function in \code{seqinr} package or \code{readDNAStringSet} function in \code{Biostrings} package for input.
		#' @param auto_tidy default FALSE; Whether trim the files in the \code{microtable} object automatically;
		#'   If TRUE, running the functions in \code{microtable} class can invoke the \code{tidy_dataset} function automatically.
		#' @return an object of class \code{microtable} with the following components:
		#' \describe{
		#'   \item{\code{sample_table}}{The sample information table.}
		#'   \item{\code{otu_table}}{The feature table.}
		#'   \item{\code{tax_table}}{The taxonomic table.}
		#'   \item{\code{phylo_tree}}{The phylogenetic tree.}
		#'   \item{\code{rep_fasta}}{The representative sequence.}
		#'   \item{\code{taxa_abund}}{default NULL; use \code{cal_abund} function to calculate.}
		#'   \item{\code{alpha_diversity}}{default NULL; use \code{cal_alphadiv} function to calculate.}
		#'   \item{\code{beta_diversity}}{default NULL; use \code{cal_betadiv} function to calculate.}
		#' }
		#' @format microtable.
		#' @examples
		#' data(otu_table_16S)
		#' data(taxonomy_table_16S)
		#' data(sample_info_16S)
		#' data(phylo_tree_16S)
		#' dataset <- microtable$new(otu_table = otu_table_16S)
		#' dataset <- microtable$new(sample_table = sample_info_16S, otu_table = otu_table_16S, 
		#'   tax_table = taxonomy_table_16S, phylo_tree = phylo_tree_16S)
		#' # trim the files in the dataset
		#' dataset$tidy_dataset()
		initialize = function(otu_table, sample_table = NULL, tax_table = NULL, phylo_tree = NULL, rep_fasta = NULL, auto_tidy = FALSE)
			{
			if(missing(otu_table)){
				stop("otu_table must be provided!")
			}
			if(!all(sapply(otu_table, is.numeric))){
				stop("Some columns in otu_table are not numeric vector! Please check the otu_table!")
			}else{
				otu_table <- private$check_abund_table(otu_table)
				self$otu_table <- otu_table
			}
			if(is.null(sample_table)){
				message("No sample_table provided, automatically use colnames in otu_table to create one ...")
				self$sample_table <- data.frame(SampleID = colnames(otu_table), Group = colnames(otu_table)) %>% 
					`row.names<-`(.$SampleID)
			}else{
				self$sample_table <- sample_table
			}
			# check whether phylogenetic tree is rooted
			if(!is.null(phylo_tree)){
				if(!ape::is.rooted(phylo_tree)){
					phylo_tree <- ape::multi2di(phylo_tree)
				}
			}
			
			self$tax_table <- tax_table
			self$phylo_tree <- phylo_tree
			self$rep_fasta <- rep_fasta
			self$taxa_abund <- NULL
			self$alpha_diversity <- NULL
			self$beta_diversity <- NULL
			self$auto_tidy <- auto_tidy
			if(self$auto_tidy) self$tidy_dataset()
		},
		#' @description
		#' Filter the features considered pollution in \code{microtable$tax_table}.
		#' This operation will remove any line of the \code{microtable$tax_table} containing any the word in taxa parameter regardless of word case.
		#'
		#' @param taxa default \code{c("mitochondria", "chloroplast")}; filter mitochondria and chloroplast, or others as needed.
		#' @return None
		#' @examples 
		#' dataset$filter_pollution(taxa = c("mitochondria", "chloroplast"))
		filter_pollution = function(taxa = c("mitochondria", "chloroplast")){
			if(is.null(self$tax_table)){
				stop("The tax_table in the microtable object is NULL ! Please check it!")
			}else{
				tax_table_use <- self$tax_table
			}
			if(length(taxa) > 1){
				taxa <- paste0(taxa, collapse = "|")
			}
			tax_table_use %<>% base::subset(unlist(lapply(data.frame(t(.)), function(x) !any(grepl(taxa, x, ignore.case = TRUE)))))
			filter_num <- nrow(self$tax_table) - nrow(tax_table_use)
			message(paste("Total", filter_num, "taxa are removed from tax_table ..."))
			self$tax_table <- tax_table_use
			if(self$auto_tidy) self$tidy_dataset()
		},
		#' @description
		#' Filter the feature with low abundance and/or low occurrence frequency.
		#'
		#' @param rel_abund default 0; the relative abundance threshold, such as 0.0001.
		#' @param freq default 1; the occurrence frequency threshold. 
		#' 	 For example, the number 2 represents filtering the feature that occurs less than 2 times.
		#' 	 A number smaller than 1 is also allowable. 
		#' 	 For instance, the number 0.1 represents filtering the feature that occurs in less than 10\% samples.
		#' @param include_lowest default TRUE; whether include the feature with the threshold.
		#' @return None
		#' @examples
		#' \donttest{
		#' d1 <- clone(dataset)
		#' d1$filter_taxa(rel_abund = 0.0001, freq = 0.2)
		#' }
		filter_taxa = function(rel_abund = 0, freq = 1, include_lowest = TRUE){
			raw_otu_table <- self$otu_table
			if(rel_abund != 0){
				if(rel_abund >= 1){
					stop("rel_abund must be smaller than 1!")
				}
				taxa_raw_abund <- self$taxa_sums()
				taxa_rel_abund <- taxa_raw_abund/sum(taxa_raw_abund)
				if(include_lowest){
					abund_names <- taxa_rel_abund[taxa_rel_abund < rel_abund] %>% names
				}else{
					abund_names <- taxa_rel_abund[taxa_rel_abund <= rel_abund] %>% names
				}
				if(length(abund_names) == nrow(raw_otu_table)){
					stop("No feature remained! Please check the rel_abund parameter!")
				}else{
					message(length(abund_names), " features filtered based on the abundance ...")
				}
			}else{
				abund_names <- c()
			}
			if(freq != 0){
				if(freq < 1){
					message("freq smaller than 1; first convert it to an integer ...")
					freq <- round(ncol(raw_otu_table) * freq)
					message("Use converted freq integer: ", freq, " for the following filtering ...")
				}
				taxa_occur_num <- apply(raw_otu_table, 1, function(x){sum(x != 0)})
				if(include_lowest){
					freq_names <- taxa_occur_num[taxa_occur_num < freq] %>% names
				}else{
					freq_names <- taxa_occur_num[taxa_occur_num <= freq] %>% names
				}
				if(length(freq_names) == nrow(raw_otu_table)){
					stop("No feature remained! Please check the freq parameter!")
				}else{
					message(length(freq_names), " features filtered based on the occurrence...")
				}
			}else{
				freq_names <- c()
			}
			filter_names <- c(abund_names, freq_names) %>% unique
			if(length(filter_names) == 0){
				new_table <- raw_otu_table
			}else{
				if(length(filter_names) == nrow(raw_otu_table)){
					stop("All features are filtered! Please adjust the parameters")
				}else{
					new_table <- raw_otu_table[! rownames(raw_otu_table) %in% filter_names, ]
				}
			}
			self$otu_table <- new_table
			self$tidy_dataset()
		},
		#' @description
		#' Rarefy communities to make all samples have same feature number. See also \code{\link{rrarefy}} of \code{vegan} package for the alternative method.
		#'
		#' @param sample.size default:NULL; feature number, If not provided, use minimum number of all samples.
		#' @param rngseed random seed; default: 123.
		#' @param replace default: TRUE; See \code{\link{sample}} for the random sampling.
		#' @return None; rarefied dataset.
		#' @examples
		#' \donttest{
		#' dataset$rarefy_samples(sample.size = min(dataset$sample_sums()), replace = TRUE)
		#' }
		rarefy_samples = function(sample.size = NULL, rngseed = 123, replace = TRUE){
			set.seed(rngseed)
			self$tidy_dataset()
			if(is.null(sample.size)){
				sample.size <- min(self$sample_sums())
				message("Use the minimum number across samples: ", sample.size)
			}
			if (length(sample.size) > 1) {
				stop("`sample.size` had more than one value !")
			}
			if (sample.size <= 0) {
				stop("sample.size less than or equal to zero. ", "Need positive sample size to work !")
			}
			if (max(self$sample_sums()) < sample.size){
				stop("sample.size is larger than the maximum of sample sums, pleasure check input sample.size !")
			}
			if (min(self$sample_sums()) < sample.size) {
				rmsamples <- self$sample_names()[self$sample_sums() < sample.size]
				message(length(rmsamples), " samples removed, ", "because they contained fewer reads than `sample.size`.")
				self$sample_table <- base::subset(self$sample_table, ! self$sample_names() %in% rmsamples)
				self$tidy_dataset()
			}
			newotu <- self$otu_table
			newotu <- as.data.frame(apply(newotu, 2, private$rarefaction_subsample, sample.size = sample.size, replace = replace))
			rownames(newotu) <- self$taxa_names()
			self$otu_table <- newotu
			# remove OTUs with 0 sequence
			rmtaxa <- self$taxa_names()[self$taxa_sums() == 0]
			if (length(rmtaxa) > 0) {
				message(length(rmtaxa), " OTUs were removed because they are no longer present in any sample after random subsampling ...")
				self$tax_table <- base::subset(self$tax_table, ! self$taxa_names() %in% rmtaxa)
				self$tidy_dataset()
			}
		},
		#' @description
		#' Trim all the data in the \code{microtable} object to make taxa and samples consistent. So the results are intersections.
		#'
		#' @param main_data default FALSE; if TRUE, only basic data in \code{microtable} object is trimmed. Otherwise, all data, 
		#' 	  including \code{taxa_abund}, \code{alpha_diversity} and \code{beta_diversity}, are all trimed.
		#' @return None, object of \code{microtable} itself cleaned up. 
		#' @examples
		#' dataset$tidy_dataset(main_data = TRUE)
		tidy_dataset = function(main_data = FALSE){
			# check whether there is 0 abundance in otu_table
			self$otu_table <- private$check_abund_table(self$otu_table)
			
			sample_names <- intersect(rownames(self$sample_table), colnames(self$otu_table))
			if(length(sample_names) == 0){
				stop("No same sample name found between rownames of sample_table and colnames of otu_table! Please check whether the rownames of sample_table are sample names!")
			}
			# keep the sample order same with raw sample table
			sample_names <- rownames(self$sample_table) %>% .[. %in% sample_names]
			self$sample_table %<>% .[sample_names, , drop = FALSE]
			self$otu_table %<>% .[ , sample_names, drop = FALSE]
			# trim taxa
			self$otu_table %<>% {.[apply(., 1, sum) > 0, , drop = FALSE]}
			taxa_list <- list(rownames(self$otu_table), rownames(self$tax_table), self$phylo_tree$tip.label) %>% 
				.[!unlist(lapply(., is.null))]
			taxa_names <- Reduce(intersect, taxa_list)
			if(length(taxa_names) == 0){
				if(is.null(self$phylo_tree)){
					stop("No same feature names found between rownames of otu_table and rownames of tax_table! Please check rownames of those tables !")
				}else{
					stop("No same feature name found among otu_table, tax_table and phylo_tree! Please check feature names in those objects !")
				}
			}
			self$otu_table %<>% .[taxa_names, , drop = FALSE]
			if(!is.null(self$tax_table)){
				self$tax_table %<>% .[taxa_names, , drop = FALSE]
			}
			if(!is.null(self$phylo_tree)){
				self$phylo_tree %<>% ape::drop.tip(., base::setdiff(.$tip.label, taxa_names))
			}
			if(!is.null(self$rep_fasta)){
				# first check the relationship among names
				if(!all(taxa_names %in% names(self$rep_fasta))){
					stop("Some feature names are not found in the names of rep_fasta! Please provide a complete fasta file or manually check the names!")
				}
				self$rep_fasta %<>% .[taxa_names]
			}
			# other files will also be changed if main_data FALSE
			if(main_data == F){
				if(!is.null(self$taxa_abund)){
					self$taxa_abund %<>% lapply(., function(x) x[, sample_names, drop = FALSE])
				}
				if(!is.null(self$alpha_diversity)){
					self$alpha_diversity %<>% .[sample_names, , drop = FALSE]
				}
				if(!is.null(self$beta_diversity)){
					self$beta_diversity %<>% lapply(., function(x) x[sample_names, sample_names, drop = FALSE])
				}
			}
		},
		#' @description
		#' Add the rownames of \code{microtable$tax_table} as its last column. 
		#' This is especially useful when the rownames of \code{microtable$tax_table} are required as a taxonomic level 
		#' 	 for the taxonomic abundance calculation and biomarker idenfification.
		#'
		#' @param use_name default "OTU"; The column name used in the \code{tax_table}.
		#' @return NULL, a new tax_table stored in the object.
		#' @examples
		#' \donttest{
		#' dataset$add_rownames2taxonomy()
		#' }
		add_rownames2taxonomy = function(use_name = "OTU"){
			if(is.null(self$tax_table)){
				stop("The tax_table in the microtable object is NULL ! However it is necessary!")
			}else{
				tax_table_use <- self$tax_table
			}
			tax_table_use <- data.frame(tax_table_use, rownames(tax_table_use), check.names = FALSE, stringsAsFactors = FALSE)
			if(use_name %in% colnames(tax_table_use)){
				stop("The input use_name: ", use_name, " has been used in the raw tax_table! Please check it!")
			}
			colnames(tax_table_use)[ncol(tax_table_use)] <- use_name
			self$tax_table <- tax_table_use
		},
		#' @description
		#' Sum the species number for each sample.
		#'
		#' @return species number of samples.
		#' @examples
		#' \donttest{
		#' dataset$sample_sums()
		#' }
		sample_sums = function(){
			colSums(self$otu_table)
		},
		#' @description
		#' Sum the species number for each taxa.
		#'
		#' @return species number of taxa.
		#' @examples
		#' \donttest{
		#' dataset$taxa_sums()
		#' }
		taxa_sums = function(){
			rowSums(self$otu_table)
		},
		#' @description
		#' Show sample names.
		#'
		#' @return sample names.
		#' @examples
		#' \donttest{
		#' dataset$sample_names()
		#' }
		sample_names = function(){
			rownames(self$sample_table)
		},
		#' @description
		#' Show taxa names of tax_table.
		#'
		#' @return taxa names.
		#' @examples
		#' \donttest{
		#' dataset$taxa_names()
		#' }
		taxa_names = function(){
			rownames(self$tax_table)
		},
		#' @description
		#' Rename the features, including the rownames of \code{otu_table}, rownames of \code{tax_table}, tip labels of \code{phylo_tree} and \code{rep_fasta}.
		#'
		#' @param newname_prefix default "ASV_"; the prefix of new names; new names will be newname_prefix + numbers according to the rownames order of \code{otu_table}.
		#' @return None; renamed dataset.
		#' @examples
		#' \donttest{
		#' dataset$rename_taxa()
		#' }
		rename_taxa = function(newname_prefix = "ASV_"){
			self$tidy_dataset()
			# extract old names for futher matching
			old_names <- rownames(self$otu_table)
			new_names <- paste0(newname_prefix, seq_len(nrow(self$otu_table)))
			rownames(self$otu_table) <- new_names
			if(!is.null(self$tax_table)){
				rownames(self$tax_table) <- new_names
			}
			if(!is.null(self$phylo_tree)){
				self$phylo_tree$tip.label[match(old_names, self$phylo_tree$tip.label)] <- new_names
			}
			if(!is.null(self$rep_fasta)){
				names(self$rep_fasta)[match(old_names, names(self$rep_fasta))] <- new_names
			}
		},
		#' @description
		#' Merge samples according to specific group to generate a new \code{microtable}.
		#'
		#' @param use_group the group column in \code{sample_table}.
		#' @return a new merged microtable object.
		#' @examples
		#' \donttest{
		#' dataset$merge_samples(use_group = "Group")
		#' }
		merge_samples = function(use_group){
			otu_table <- self$otu_table
			sample_table <- self$sample_table
			if(!is.null(self$tax_table)){
				tax_table <- self$tax_table
			}else{
				tax_table <- NULL
			}
			if(!is.null(self$phylo_tree)){
				phylo_tree <- self$phylo_tree
			}else{
				phylo_tree <- NULL
			}
			if(!is.null(self$rep_fasta)){
				rep_fasta <- self$rep_fasta
			}else{
				rep_fasta <- NULL
			}
			otu_table_new <- rowsum(t(otu_table), as.factor(as.character(sample_table[, use_group]))) %>% t %>% as.data.frame
			sample_table_new <- data.frame(SampleID = unique(as.character(sample_table[, use_group]))) %>% `row.names<-`(.[,1])
			# return a new microtable object
			microtable$new(
				sample_table = sample_table_new, 
				otu_table = otu_table_new, 
				tax_table = tax_table, 
				phylo_tree = phylo_tree, 
				rep_fasta = rep_fasta,
				auto_tidy = self$auto_tidy
			)
		},
		#' @description
		#' Merge taxa according to specific taxonomic rank to generate a new \code{microtable}.
		#'
		#' @param taxa default "Genus"; the specific rank in \code{tax_table}.
		#' @return a new merged \code{microtable} object.
		#' @examples
		#' \donttest{
		#' dataset$merge_taxa(taxa = "Genus")
		#' }
		merge_taxa = function(taxa = "Genus"){
			# Agglomerate all OTUs by given taxonomic level
			ranknumber <- which(colnames(self$tax_table) %in% taxa)
			sampleinfo <- self$sample_table
			abund <- self$otu_table
			tax <- self$tax_table
			tax <- tax[, 1:ranknumber, drop=FALSE]
			# concatenate taxonomy in case of duplicated taxa names
			merged_taxonomy <- apply(tax, 1, paste, collapse="|")
			abund1 <- cbind.data.frame(Display = merged_taxonomy, abund) %>% 
				reshape2::melt(id.var = "Display", value.name= "Abundance", variable.name = "Sample")
			abund1 <- data.table(abund1)[, sum_abund:=sum(Abundance), by=list(Display, Sample)] %>% 
				.[, c("Abundance"):=NULL] %>% 
				setkey(Display, Sample) %>% 
				unique() %>% 
				as.data.frame()
			# use dcast to generate table
			new_abund <- as.data.frame(data.table::dcast(data.table(abund1), Display~Sample, value.var= list("sum_abund"))) %>% 
				`row.names<-`(.[,1]) %>% 
				.[,-1, drop = FALSE]
			new_abund <- new_abund[order(apply(new_abund, 1, mean), decreasing = TRUE), rownames(sampleinfo), drop = FALSE]
			# choose OTU names with highest abundance to replace the long taxonomic information in names
			name1 <- cbind.data.frame(otuname = rownames(tax), Display = merged_taxonomy, abundance = apply(abund[rownames(tax), ], 1, sum))
			name1 <- data.table(name1)[, max_abund:=max(abundance), by = Display]
			name1 <- name1[max_abund == abundance] %>% 
				.[, c("abundance", "max_abund"):=NULL] %>% 
				setkey(Display) %>% 
				unique() %>% 
				as.data.frame()
			name1 <- name1[!duplicated(name1$Display), ] %>% 
				`row.names<-`(.$Display)
			rownames(new_abund) <- name1[rownames(new_abund), "otuname"]
			new_tax <- tax[rownames(new_abund), , drop = FALSE]
			microtable$new(sample_table = sampleinfo, otu_table = new_abund, tax_table = new_tax, auto_tidy = self$auto_tidy)
		},
		#' @description
		#' Calculate the taxonomic abundance at each taxonomic level or selected levels.
		#'
		#' @param select_cols default NULL; numeric vector or character vector of colnames of \code{microtable$tax_table}; 
		#'   applied to select columns to merge and calculate abundances according to ordered hierarchical levels.
		#'   This is very useful if there are commented columns or some columns with multiple structure that cannot be used directly.
		#' @param rel default TRUE; if TRUE, relative abundance is used; if FALSE, absolute abundance (i.e. raw values) will be summed.
		#' @param merge_by default "|"; the symbol to merge and concatenate taxonomic names of different levels.
		#' @param split_group default FALSE; if TRUE, split the rows to multiple rows according to one or more columns in \code{tax_table}. 
		#'   Very useful when multiple mapping information exist.
		#' @param split_by default "&&"; Separator delimiting collapsed values; only useful when \code{split_group = TRUE}; 
		#'   see \code{sep} parameter in \code{separate_rows} function of tidyr package.
		#' @param split_column default NULL; character vector or list; only useful when \code{split_group = TRUE}; character vector: 
		#'   fixed column or columns used for the splitting in tax_table for each abundance calculation; 
		#'   list: containing more character vectors to assign the column names to each calculation, such as list(c("Phylum"), c("Phylum", "Class")).
		#' @return taxa_abund list in object.
		#' @examples
		#' \donttest{
		#' dataset$cal_abund()
		#' }
		cal_abund = function(
			select_cols = NULL, 
			rel = TRUE, 
			merge_by = "|",
			split_group = FALSE, 
			split_by = "&&", 
			split_column = NULL
			){
			taxa_abund <- list()
			if(is.null(self$tax_table)){
				stop("No tax_table found! Please check your data!")
			}
			# check data corresponding
			if(nrow(self$tax_table) != nrow(self$otu_table)){
				message("The row number of tax_table is not equal to that of otu_table ...")
				message("Automatically applying tidy_dataset() function to trim the data ...")
				self$tidy_dataset()
				print(self)
			}
			if(nrow(self$sample_table) != ncol(self$otu_table)){
				message("The sample numbers of sample_table is not equal to that of otu_table ...")
				message("Automatically applying tidy_dataset() function to trim the data ...")
				self$tidy_dataset()
				print(self)
			}
			
			# check whether no row in tax_table
			if(nrow(self$tax_table) == 0){
				stop("0 rows in tax_table! Please check your data!")
			}
			if(is.null(select_cols)){
				select_cols <- seq_len(ncol(self$tax_table))
			}else{
				if(!is.numeric(select_cols)){
					if(any(! select_cols %in% colnames(self$tax_table))){
						stop("Part of input names of select_cols are not in the tax_table!")
					}else{
						select_cols <- match(select_cols, colnames(self$tax_table))
					}
				}
			}
			if(split_group){
				if(is.null(split_column)){
					stop("Spliting rows by one or more columns require split_column parameter! Please set split_column and try again!")
				}
			}
			for(i in seq_along(select_cols)){
				taxrank <- colnames(self$tax_table)[select_cols[i]]
				# assign the columns used for the splitting
				if(!is.null(split_column)){
					if(is.list(split_column)){
						use_split_column <- split_column[[i]]
					}else{
						use_split_column <- split_column
					}
				}
				taxa_abund[[taxrank]] <- private$transform_data_proportion(
											self, 
											columns = select_cols[1:i], 
											rel = rel, 
											merge_by = merge_by,
											split_group = split_group, 
											split_by = split_by, 
											split_column = use_split_column)
			}
			self$taxa_abund <- taxa_abund
			message('The result is stored in object$taxa_abund ...')
		},
		#' @description
		#' Save taxonomic abundance as local file.
		#'
		#' @param dirpath default "taxa_abund"; directory to save the taxonomic abundance files. It will be created if not found.
		#' @param merge_all default FALSE; Whether merge all tables into one. The merged file format is generally called 'mpa' style.
		#' @param rm_un default FALSE; Whether remove unclassified taxa in which the name ends with '__' generally.
		#' @param rm_pattern default "__$"; The pattern searched through the merged taxonomic names. See also \code{pattern} parameter in \code{\link{grepl}} function. 
		#' 	  Only available when \code{rm_un = TRUE}. The default "__$" means removing the names end with '__'.
		#' @param sep default ","; the field separator string. Same with \code{sep} parameter in \code{\link{write.table}} function.
		#' 	  default \code{','} correspond to the file name suffix 'csv'. The option \code{'\t'} correspond to the file name suffix 'tsv'. For other options, suffix are all 'txt'.
		#' @param ... parameters passed to \code{\link{write.table}}.
		#' @examples
		#' \dontrun{
		#' dataset$save_abund(dirpath = "taxa_abund")
		#' dataset$save_abund(merge_all = TRUE, rm_un = TRUE, sep = "\t")
		#' }
		save_abund = function(dirpath = "taxa_abund", merge_all = FALSE, rm_un = FALSE, rm_pattern = "__$", sep = ",", ...){
			if(!dir.exists(dirpath)){
				dir.create(dirpath)
			}
			suffix <- switch(sep, ',' = "csv", '\t' = "tsv", "txt")
			if(merge_all){
				res <- data.frame()
				for(i in names(self$taxa_abund)){
					res %<>% rbind(., self$taxa_abund[[i]])
				}
				res <- data.frame(Taxa = rownames(res), res)
				if(rm_un){
					res %<>% .[!grepl(rm_pattern, .$Taxa), ]
				}
				save_path <- paste0(dirpath, "/mpa_abund.", suffix)
				write.table(res, file = save_path, row.names = FALSE, sep = sep, ...)
				message('Save abundance to ', save_path, ' ...')
			}else{
				for(i in names(self$taxa_abund)){
					tmp <- self$taxa_abund[[i]]
					if(rm_un){
						tmp %<>% .[!grepl(rm_pattern, rownames(.)), ]
					}
					tmp <- data.frame(Taxa = rownames(tmp), tmp)
					save_path <- paste0(dirpath, "/", i, "_abund.", suffix)
					write.table(tmp, file = save_path, row.names = FALSE, sep = sep, ...)
				}
			}
		},
		#' @description
		#' Calculate alpha diversity.
		#'
		#' @param measures default NULL; one or more indexes of \code{c("Observed", "Coverage", "Chao1", "ACE", "Shannon", "Simpson", "InvSimpson", "Fisher", "PD")}; 
		#'   If null, use all those measures. 'Shannon', 'Simpson' and 'InvSimpson' are calculated based on \code{vegan::diversity} function;
		#'   'Chao1' and 'ACE' depend on the function \code{vegan::estimateR}; 'PD' depends on the function \code{picante::pd}.
		#' @param PD default FALSE; whether Faith's phylogenetic diversity should be calculated.
		#' @return alpha_diversity stored in object.
		#' @examples
		#' \donttest{
		#' dataset$cal_alphadiv(measures = NULL, PD = FALSE)
		#' class(dataset$alpha_diversity)
		#' }
		cal_alphadiv = function(measures = NULL, PD = FALSE){
			# modified based on the alpha diversity analysis of phyloseq package
			OTU <- as.data.frame(t(self$otu_table), check.names = FALSE)
			renamevec    <-     c("Observed", "Coverage", "Chao1", "ACE", "Shannon", "Simpson", "InvSimpson", "Fisher")
			names(renamevec) <- c("S.obs", "coverage", "S.chao1", "S.ACE", "shannon", "simpson", "invsimpson", "fisher")
			if(is.null(measures)){
				use_measures <- as.character(renamevec)
			}else{
				use_measures <- measures
			}
			if(any(use_measures %in% names(renamevec))){
				use_measures[use_measures %in% names(renamevec)] <- renamevec[names(renamevec) %in% use_measures]
			}
			if(!any(use_measures %in% renamevec)){
				stop("None of the `measures` you provided are supported. Try default `NULL` instead.")
			}
			outlist <- vector("list")
			estimRmeas <- c("Chao1", "Observed", "ACE")
			if(any(estimRmeas %in% use_measures)){
				outlist <- c(outlist, list(t(data.frame(vegan::estimateR(OTU), check.names = FALSE))))
			}
			if("Shannon" %in% use_measures){
				outlist <- c(outlist, list(shannon = vegan::diversity(OTU, index = "shannon")))
			}
			if("Simpson" %in% use_measures){
				outlist <- c(outlist, list(simpson = vegan::diversity(OTU, index = "simpson")))
			}
			if("InvSimpson" %in% use_measures){
				outlist <- c(outlist, list(invsimpson = vegan::diversity(OTU, index = "invsimpson")))
			}
			if("Fisher" %in% use_measures){
				fisher <- tryCatch(vegan::fisher.alpha(OTU, se = TRUE), 
					warning = function(w){suppressWarnings(vegan::fisher.alpha(OTU, se = TRUE)[, c("alpha", "se")])},
					error = function(e){c("Skip the index Fisher because of an error ...")}
					)
				if(!is.null(dim(fisher))) {
					colnames(fisher)[1:2] <- c("Fisher", "se.fisher")
					outlist <- c(outlist, list(fisher))
				}else{
					if(is.numeric(fisher)){
						outlist <- c(outlist, Fisher = list(fisher))
					}else{
						message(fisher)
					}
				}
			}
			if("Coverage" %in% use_measures){
				outlist <- c(outlist, list(coverage = private$goods(OTU)))
			}
			if(PD){
				if(is.null(self$phylo_tree)){
					stop("Please provide phylogenetic tree for PD calculation!")
				}else{
					outlist <- c(outlist, list(PD = picante::pd(OTU, self$phylo_tree)[, "PD", drop=TRUE]))
				}
			}
			res <- do.call("cbind", outlist)
			namechange <- base::intersect(colnames(res), names(renamevec))
			colnames(res)[colnames(res) %in% namechange] <- renamevec[namechange]
			self$alpha_diversity <- as.data.frame(res)
			message('The result is stored in object$alpha_diversity ...')
		},
		#' @description
		#' Save alpha diversity table to the computer.
		#'
		#' @param dirpath default "alpha_diversity"; directory name to save the alpha_diversity.csv file.
		save_alphadiv = function(dirpath = "alpha_diversity"){
			if(!dir.exists(dirpath)){
				dir.create(dirpath)
				# stop("The directory is not found, please first create it!")
			}
			write.csv(self$alpha_diversity, file = paste0(dirpath, "/", "alpha_diversity.csv"), row.names = TRUE)
		},
		#' @description
		#' Calculate beta diversity, including Bray-Curtis, Jaccard, and UniFrac.
		#' See An et al. (2019) <doi:10.1016/j.geoderma.2018.09.035> and Lozupone et al. (2005) <doi:10.1128/AEM.71.12.8228–8235.2005>.
		#'
		#' @param method default NULL; a character vector with one or more elements; If default, "bray" and "jaccard" will be used; 
		#'   see \code{\link{vegdist}} function and \code{method} parameter in \code{vegan} package. 
		#' @param unifrac default FALSE; whether UniFrac index should be calculated.
		#' @param binary default FALSE; TRUE is used for jaccard and unweighted unifrac; optional for other indexes.
		#' @param ... parameters passed to \code{\link{vegdist}} function.
		#' @return beta_diversity list stored in object.
		#' @examples
		#' \donttest{
		#' dataset$cal_betadiv(unifrac = FALSE)
		#' class(dataset$beta_diversity)
		#' }
		cal_betadiv = function(method = NULL, unifrac = FALSE, binary = FALSE, ...){
			res <- list()
			eco_table <- t(self$otu_table)
			sample_table <- self$sample_table
			if(is.null(method)){
				method <- c("bray", "jaccard")
			}
			for(i in method){
				if(i == "jaccard"){
					binary_use <- TRUE
				}else{
					binary_use <- binary
				}
				res[[i]] <- as.matrix(vegan::vegdist(eco_table, method = i, binary = binary_use, ...))
			}
			
			if(unifrac == T){
				if(is.null(self$phylo_tree)){
					stop("No phylogenetic tree provided, please change the parameter unifrac to FALSE")
				}
				phylo_tree <- self$phylo_tree
				# require GUniFrac package; do not consider too much about alpha parameter
				unifrac1 <- GUniFrac::GUniFrac(eco_table, phylo_tree, alpha = c(0, 0.5, 1))
				unifrac2 <- unifrac1$unifracs
				wei_unifrac <- unifrac2[,, "d_1"]
				res$wei_unifrac <- wei_unifrac
				unwei_unifrac <- unifrac2[,, "d_UW"]
				res$unwei_unifrac <- unwei_unifrac
			}
			self$beta_diversity <- res
			message('The result is stored in object$beta_diversity ...')
		},
		#' @description
		#' Save beta diversity matrix to the computer.
		#'
		#' @param dirpath default "beta_diversity"; directory name to save the beta diversity matrix files.
		save_betadiv = function(dirpath = "beta_diversity"){
			if(!dir.exists(dirpath)){
				dir.create(dirpath)
				# stop("The directory is not found, please first create it!")
			}
			for(i in names(self$beta_diversity)){
				write.csv(self$beta_diversity[[i]], file = paste0(dirpath, "/", i, ".csv"), row.names = TRUE)
			}
		},
		#' @description
		#' Print the microtable object.
		print = function(){
			cat("microtable-class object:\n")
			cat(paste("sample_table have", nrow(self$sample_table), "rows and", ncol(self$sample_table), "columns\n"))
			cat(paste("otu_table have", nrow(self$otu_table), "rows and", ncol(self$otu_table), "columns\n"))
			if(!is.null(self$tax_table)) cat(paste("tax_table have", nrow(self$tax_table), "rows and", ncol(self$tax_table), "columns\n"))
			if(!is.null(self$phylo_tree)) cat(paste("phylo_tree have", length(self$phylo_tree$tip.label), "tips\n"))
			if(!is.null(self$rep_fasta)) cat(paste("rep_fasta have", length(self$rep_fasta), "sequences\n"))
			if(!is.null(self$taxa_abund)) cat(paste("Taxa abundance: calculated for", paste0(names(self$taxa_abund), collapse = ","), "\n"))
			if(!is.null(self$alpha_diversity)) cat(paste("Alpha diversity: calculated for", paste0(colnames(self$alpha_diversity), collapse = ","), "\n"))
			if(!is.null(self$beta_diversity)) cat(paste("Beta diversity: calculated for", paste0(names(self$beta_diversity), collapse = ","), "\n"))
			invisible(self)
		}
		),
	private = list(
		# check whether there is OTU or sample with 0 abundance
		# input and return are both otu_table
		check_abund_table = function(otu_table){
			if(any(apply(otu_table, 1, sum) == 0)){
				remove_num <- sum(apply(otu_table, 1, sum) == 0)
				message(remove_num, " taxa are removed from the otu_table, as the abundance is 0 ...")
				otu_table %<>% .[apply(., 1, sum) > 0, , drop = FALSE]
			}
			if(any(apply(otu_table, 2, sum) == 0)){
				remove_num <- sum(apply(otu_table, 2, sum) == 0)
				message(remove_num, " samples are removed from the otu_table, as the abundance is 0 ...")
				otu_table %<>% .[, apply(., 2, sum) > 0, drop = FALSE]
			}
			if(ncol(otu_table) == 0){
				stop("No sample have abundance! Please check you data!")
			}
			if(nrow(otu_table) == 0){
				stop("No taxon have abundance! Please check you data!")
			}
			otu_table
		},
		# taxa abundance calculation
		transform_data_proportion = function(
			input,
			columns,
			rel,
			merge_by = "|",
			split_group = FALSE,
			split_by = "&&",
			split_column
			){
			sampleinfo <- input$sample_table
			abund <- input$otu_table
			tax <- input$tax_table
			tax <- tax[, columns, drop=FALSE]
			# split rows to multiple rows if multiple correspondence
			if(split_group){
				merge_abund <- cbind.data.frame(tax, abund)
				split_merge_abund <- tidyr::separate_rows(merge_abund, all_of(split_column), sep = split_by)
				new_tax <- split_merge_abund[, columns, drop = FALSE]
				new_abund <- split_merge_abund[, (ncol(tax) + 1):(ncol(merge_abund)), drop = FALSE]
				abund1 <- cbind.data.frame(Display = apply(new_tax, 1, paste, collapse = merge_by), new_abund)
			}else{
				abund1 <- cbind.data.frame(Display = apply(tax, 1, paste, collapse = merge_by), abund)
			}
			# first convert table to long format
			# then sum abundance by sample and taxonomy
			abund1 <- abund1 %>% 
				data.table() %>% 
				data.table::melt(id.vars = "Display", value.name= "Abundance", variable.name = "Sample") %>%
				.[, sum_abund:=sum(Abundance), by=list(Display, Sample)] %>% 
				.[, c("Abundance"):=NULL] %>% 
				setkey(Display, Sample) %>% 
				unique()
			if(rel == T){
				abund1 <- abund1[, res_abund:=sum_abund/sum(sum_abund), by=list(Sample)] %>% 
					.[, c("sum_abund"):=NULL]
			}else{
				colnames(abund1)[colnames(abund1) == "sum_abund"] <- "res_abund"
			}
			# dcast the table
			abund2 <- as.data.frame(data.table::dcast(abund1, Display ~ Sample, value.var = list("res_abund"))) %>%
				`row.names<-`(.[,1]) %>% 
				.[,-1, drop = FALSE]
			abund2 <- abund2[order(apply(abund2, 1, mean), decreasing = TRUE), rownames(sampleinfo), drop = FALSE]
			abund2
		},
		rarefaction_subsample = function(x, sample.size, replace=FALSE){
			# Adapted from the rarefy_even_depth() in phyloseq package, see Paul et al. (2013) <doi:10.1371/journal.pone.0061217>.
			# All rights reserved.
			# Create replacement species vector
			rarvec <- numeric(length(x))
			# Perform the sub-sampling. Suppress warnings due to old R compat issue.
			if(sum(x) <= 0){
				# Protect against, and quickly return an empty vector, 
				# if x is already an empty count vector
				return(rarvec)
			}
			if(replace){
				suppressWarnings(subsample <- sample(1:length(x), sample.size, replace = TRUE, prob=x))
			} else {
				# resample without replacement
				obsvec <- apply(data.frame(OTUi=1:length(x), times=x), 1, function(x){
					rep_len(x["OTUi"], x["times"])
				})
				obsvec <- unlist(obsvec, use.names=FALSE)
				suppressWarnings(subsample <- sample(obsvec, sample.size, replace = FALSE))
			}
			sstab <- table(subsample)
			# Assign the tabulated random subsample values to the species vector
			rarvec[as(names(sstab), "integer")] <- sstab
			return(rarvec)
		},
		# define coverage function
		goods = function(com){
			no.seqs <- rowSums(com)
			sing <- com==1
			no.sing <- apply(sing, 1, sum)
			goods <- 1-no.sing/no.seqs
			return(goods)
		}
	),
	lock_objects = FALSE,
	lock_class = FALSE
)
