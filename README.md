# memory_controller
Scheduler portion of memory controller

### How to run the project in QuestSim using .do files

#### Normal mode:
##### Level 0: Closed Page Policy
do level0.do

##### Level 0: Closed Page Policy
do level1.do

#### Debug mode:
##### Level 0: Closed Page Policy
do level0_debug.do

##### Level 0: Closed Page Policy
do level1_debug.do



#### Editing .do files
If you wish to give input and output files names, you need to give those names in .do files.

Add the flag for input and output files for vsim command as follows:

vsim work.testbench +input_file=example_input_file.txt +output_file=example_output_File.txt



run