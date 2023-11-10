# memory_controller
Scheduler portion of memory controller

### How to compile the code

#### Normal mode:
vlog testbench.sv

#### Debug mode:
vlog testbench.sv +define+DEBUG


### Simulating the code

#### When user gives input and output file names:
vsim work.testbench +input_file=example.txt +output_file=example_out.txt

#### To use default input and output file names:
vsim work.testbench


run